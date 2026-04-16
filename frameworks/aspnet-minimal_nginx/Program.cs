using System.Text.Json;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.Extensions.Caching.Distributed;
using Microsoft.Extensions.Caching.Hybrid;
using Npgsql;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();

builder.WebHost.ConfigureKestrel(options =>
{
    options.ListenAnyIP(8080, lo =>
    {
        lo.Protocols = HttpProtocols.Http1;
    });
});

// ── Optional Redis + HybridCache (production-stack profile) ───────────────
//
// The production-stack profile sets REDIS_URL via docker compose. When it's
// present we register TWO caching layers:
//
//   1. IDistributedCache (StackExchange.Redis) — L2 backing store
//   2. HybridCache (Microsoft.Extensions.Caching.Hybrid) — unified API that
//      layers an in-process L1 in front of L2. Handlers inject HybridCache
//      and call GetOrCreateAsync; Microsoft's implementation handles
//      L1 lookup → L2 lookup → factory fallthrough → populate both layers
//      → return, along with stampede protection for concurrent misses.
//
// This is the idiomatic .NET 9+ pattern for the exact problem we're solving:
// "Redis is our bottleneck, add in-process caching without losing the
// distributed backing store". Real production ASP.NET apps at scale use
// exactly this setup.
//
// gateway-64 / gateway-h3 profiles don't set REDIS_URL, so neither service
// is registered and the /api/* routes below are skipped entirely.
var redisUrl = Environment.GetEnvironmentVariable("REDIS_URL");
if (!string.IsNullOrWhiteSpace(redisUrl))
{
    var hostPort = redisUrl
        .Replace("redis://", "", StringComparison.OrdinalIgnoreCase)
        .TrimEnd('/');

    // L2: StackExchange.Redis-backed IDistributedCache. HybridCache uses
    // this as its distributed tier when one is registered; without it,
    // HybridCache degrades to L1-only (memory).
    builder.Services.AddStackExchangeRedisCache(options =>
    {
        options.Configuration = $"{hostPort},abortConnect=false,connectTimeout=2000,syncTimeout=2000";
    });

    // L1+L2: HybridCache with a default 1s TTL at both layers. L1 is
    // IMemoryCache in-process; L2 picks up IDistributedCache automatically.
    #pragma warning disable EXTEXP0018 // HybridCache still marked experimental in 9.x
    builder.Services.AddHybridCache(options =>
    {
        options.DefaultEntryOptions = new HybridCacheEntryOptions
        {
            Expiration           = TimeSpan.FromSeconds(1),
            LocalCacheExpiration = TimeSpan.FromSeconds(1),
        };
    });
    #pragma warning restore EXTEXP0018
}

var app = builder.Build();

AppData.Load();

// ── gateway-64 routes (unchanged) ───────────────────────────────────────────

app.MapGet("/baseline2", Handlers.Sum);
app.MapGet("/json/{count}", Handlers.Json);
app.MapGet("/async-db", Handlers.AsyncDatabase);

// ── production-stack public routes (no auth, no cache) ─────────────────────

app.MapGet("/public/baseline", Handlers.Sum);
app.MapGet("/public/json/{count}", Handlers.Json);

// ── production-stack cached routes ─────────────────────────────────────────
//
// Everything below requires the HybridCache + IDistributedCache services,
// which are only registered when REDIS_URL is set (production-stack profile).
// For gateway-64 and gateway-h3 those services aren't in DI at all, so we
// skip registering these routes entirely — otherwise ASP.NET's endpoint
// builder tries to bind HybridCache as a body parameter at startup and every
// route on the server returns 500, including /baseline2.

if (!string.IsNullOrWhiteSpace(redisUrl))
{
    // Precompiled JsonSerializerOptions — reused for all hot-path JSON writes.
    var jsonOpts = new JsonSerializerOptions(JsonSerializerDefaults.Web);

    // Per-endpoint HybridCache options. Items use 1s at both layers (short
    // so Postgres sees regular traffic on invalidation); users use 30s
    // since profiles change rarely.
    var itemCacheOptions = new HybridCacheEntryOptions
    {
        Expiration           = TimeSpan.FromSeconds(1),
        LocalCacheExpiration = TimeSpan.FromSeconds(1),
    };
    var userCacheOptions = new HybridCacheEntryOptions
    {
        Expiration           = TimeSpan.FromSeconds(30),
        LocalCacheExpiration = TimeSpan.FromSeconds(30),
    };

    // /api/items/{id} GET — HybridCache cache-aside.
    //
    // HybridCache.GetOrCreateAsync handles the whole L1 → L2 → factory flow:
    //   1. Check L1 (in-process IMemoryCache) by key
    //   2. Miss → check L2 (Redis via IDistributedCache) by key
    //   3. Miss → run the factory to produce the value, populate BOTH layers
    //   4. Return the value
    //
    // Built-in stampede protection: if 1000 concurrent requests miss the
    // same key, only one factory runs; the other 999 wait for it. No manual
    // locking needed in handler code.
    //
    // wasMiss is captured in the factory closure so we can report the
    // X-Cache: MISS vs HIT header to the client. It's only flipped inside
    // the factory, which runs at most once per GetOrCreateAsync call.
    app.MapGet("/api/items/{id:int}", async (int id, HybridCache cache, HttpContext ctx, CancellationToken ct) =>
    {
        var wasMiss = false;
        var cacheKey = $"item:{id}";

        var json = await cache.GetOrCreateAsync<string>(
            cacheKey,
            async cancel =>
            {
                wasMiss = true;
                if (AppData.PgDataSource is null) return "";

                await using var cmd = AppData.PgDataSource.CreateCommand(
                    "SELECT id, name, category, price, quantity, active, rating_score, rating_count " +
                    "FROM items WHERE id = $1 LIMIT 1");
                cmd.Parameters.AddWithValue(id);

                await using var reader = await cmd.ExecuteReaderAsync(cancel);
                if (!await reader.ReadAsync(cancel)) return "";

                return JsonSerializer.Serialize(new
                {
                    id       = reader.GetInt32(0),
                    name     = reader.GetString(1),
                    category = reader.GetString(2),
                    price    = reader.GetInt32(3),
                    quantity = reader.GetInt32(4),
                    active   = reader.GetBoolean(5),
                    rating   = new
                    {
                        score = reader.GetInt32(6),
                        count = reader.GetInt32(7),
                    },
                }, jsonOpts);
            },
            itemCacheOptions,
            cancellationToken: ct);

        if (string.IsNullOrEmpty(json))
        {
            ctx.Response.StatusCode = 404;
            return;
        }

        ctx.Response.Headers["X-Cache"] = wasMiss ? "MISS" : "HIT";
        ctx.Response.ContentType = "application/json";
        await ctx.Response.WriteAsync(json);
    });

    // /api/items/{id} POST — update + HybridCache invalidate.
    //
    // HybridCache.RemoveAsync clears the key from BOTH L1 and L2. Next GET
    // on the same key will fall through to the factory and re-populate
    // from Postgres.
    app.MapPost("/api/items/{id:int}", async (int id, HybridCache cache, HttpContext ctx) =>
    {
        ItemUpdate? update;
        try
        {
            update = await JsonSerializer.DeserializeAsync<ItemUpdate>(ctx.Request.Body, jsonOpts);
        }
        catch
        {
            ctx.Response.StatusCode = 400;
            return;
        }
        if (update is null)
        {
            ctx.Response.StatusCode = 400;
            return;
        }

        if (AppData.PgDataSource is null)
        {
            ctx.Response.StatusCode = 503;
            return;
        }

        await using var cmd = AppData.PgDataSource.CreateCommand(
            "UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4");
        cmd.Parameters.AddWithValue(update.Name);
        cmd.Parameters.AddWithValue(update.Price);
        cmd.Parameters.AddWithValue(update.Quantity);
        cmd.Parameters.AddWithValue(id);
        var affected = await cmd.ExecuteNonQueryAsync();
        if (affected == 0)
        {
            ctx.Response.StatusCode = 404;
            return;
        }

        await cache.RemoveAsync($"item:{id}");

        ctx.Response.StatusCode = 204;
    });

    // /api/me GET — HybridCache cache-aside on the users table.
    //
    // Same pattern as /api/items/{id} but reads a user row by X-User-Id
    // header that was set by the edge after auth_request validated the
    // session cookie. The framework trusts the header completely — nginx
    // strips any client-supplied X-User-Id before running auth_request.
    app.MapGet("/api/me", async (HybridCache cache, HttpContext ctx, CancellationToken ct) =>
    {
        var userIdHeader = ctx.Request.Headers["X-User-Id"].ToString();
        if (string.IsNullOrWhiteSpace(userIdHeader) || !int.TryParse(userIdHeader, out var uid))
        {
            ctx.Response.StatusCode = 401;
            return;
        }

        var wasMiss = false;
        var cacheKey = $"user:{uid}";

        var json = await cache.GetOrCreateAsync<string>(
            cacheKey,
            async cancel =>
            {
                wasMiss = true;
                if (AppData.PgDataSource is null) return "";

                await using var cmd = AppData.PgDataSource.CreateCommand(
                    "SELECT id, name, email, plan FROM users WHERE id = $1 LIMIT 1");
                cmd.Parameters.AddWithValue(uid);

                await using var reader = await cmd.ExecuteReaderAsync(cancel);
                if (!await reader.ReadAsync(cancel)) return "";

                return JsonSerializer.Serialize(new
                {
                    id    = reader.GetInt32(0),
                    name  = reader.GetString(1),
                    email = reader.GetString(2),
                    plan  = reader.GetString(3),
                }, jsonOpts);
            },
            userCacheOptions,
            cancellationToken: ct);

        if (string.IsNullOrEmpty(json))
        {
            ctx.Response.StatusCode = 404;
            return;
        }

        ctx.Response.Headers["X-Cache"] = wasMiss ? "MISS" : "HIT";
        ctx.Response.ContentType = "application/json";
        await ctx.Response.WriteAsync(json);
    });
}

app.Run();

record ItemUpdate(string Name, int Price, int Quantity);
