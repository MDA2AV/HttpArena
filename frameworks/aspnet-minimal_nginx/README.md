# aspnet-minimal + nginx

ASP.NET Core minimal API behind Nginx reverse proxy. Participates in `gateway-64` (h2 proxy+server) and `production-stack` (full CRUD with JWT auth + cache-aside).

## Stack

- **Language:** C# / .NET 10
- **Framework:** ASP.NET Core Minimal APIs
- **Engine:** Kestrel (HTTP/1.1 on port 8080, behind nginx)
- **Proxy:** nginx 1.27-alpine (TLS termination, static files, auth_request)
- **Build:** Framework-dependent publish, `mcr.microsoft.com/dotnet/aspnet:10.0` runtime with `libgssapi-krb5-2`

## Tests

### gateway-64

Two-service stack: nginx proxy + ASP.NET server. Nginx handles TLS and static files, proxies dynamic endpoints to Kestrel. No auth, no cache.

| Endpoint | Method | Description |
|---|---|---|
| `/static/*` | GET | Served by nginx from disk with `gzip_static` |
| `/baseline2` | GET | Sums query parameter values |
| `/json/{count}` | GET | Dataset processing, returns `count` items with computed `total` |
| `/async-db` | GET | Postgres range query with connection pooling via `NpgsqlDataSource` |

### production-stack

Four-service stack: nginx edge + Redis cache + shared Rust authsvc (JWT) + ASP.NET server.

| Endpoint | Method | Auth | Cache | Description |
|---|---|---|---|---|
| `/static/*` | GET | no | no | Served by nginx |
| `/public/baseline` | GET | no | no | Query-sum |
| `/public/json/{count}` | GET | no | no | Dataset serialization |
| `/api/items/{id}` | GET | JWT | HybridCache L1+L2 | Cache-aside read: L1 (IMemoryCache) → L2 (Redis via IDistributedCache) → Postgres SELECT |
| `/api/items/{id}` | POST | JWT | invalidate L1+L2 | Parse JSON body, Postgres UPDATE, `HybridCache.RemoveAsync` |
| `/api/me` | GET | JWT | HybridCache L1+L2 | Read user by `X-User-Id` header, cache-aside from `users` table |

## Cache implementation

Uses `Microsoft.Extensions.Caching.Hybrid.HybridCache` — the idiomatic .NET 9+ two-tier cache:

- **L1**: in-process `IMemoryCache` (~100 ns lookups, no network)
- **L2**: Redis via `Microsoft.Extensions.Caching.StackExchangeRedis` (~50 µs HMGET on localhost)
- **Factory**: `GetOrCreateAsync<string>(key, factory, options)` handles the full L1 → L2 → DB fallthrough + population flow, with built-in stampede protection (concurrent misses on the same key only run one factory)

TTLs: items at 1 second (both layers), users at 30 seconds.

Registered at startup:
```csharp
builder.Services.AddStackExchangeRedisCache(options => { ... });
builder.Services.AddHybridCache(options => {
    options.DefaultEntryOptions = new HybridCacheEntryOptions {
        Expiration           = TimeSpan.FromSeconds(1),
        LocalCacheExpiration = TimeSpan.FromSeconds(1),
    };
});
```

Injected into handlers:
```csharp
app.MapGet("/api/items/{id:int}", async (int id, HybridCache cache, HttpContext ctx, CancellationToken ct) =>
{
    var json = await cache.GetOrCreateAsync<string>($"item:{id}", async cancel => {
        // Postgres SELECT — only runs on L1+L2 miss
    }, itemCacheOptions, cancellationToken: ct);
});
```

## Auth

The framework does **no authentication**. JWT verification happens at the nginx edge via `auth_request` → the shared Rust authsvc sidecar. ASP.NET receives requests with a trusted `X-User-Id` header already set.

## CPU split (production-stack)

Empirically tuned for this entry:

| Service | Physical | Logical | Role |
|---|---|---|---|
| edge (nginx) | 15 | 30 | TLS + h2 + auth_request subrequests |
| cache (Redis) | 1 | 2 | L2 backing store (single-threaded) |
| authsvc (Rust) | 4 | 8 | JWT HMAC-SHA256 verification |
| server (ASP.NET) | 12 | 24 | CRUD handlers + HybridCache + Npgsql |

## Notes

- `libgssapi-krb5-2` installed in the runtime image — required by `StackExchange.Redis` for TLS/auth layer initialization (crashes without it even on plain TCP)
- Routes behind `/api/*` are only registered when `REDIS_URL` is set (guarded by `if (!string.IsNullOrWhiteSpace(redisUrl))`) — otherwise ASP.NET's endpoint builder fails to resolve `HybridCache` as a DI dependency and every route returns 500
- Postgres runs on tmpfs (`--tmpfs /var/lib/postgresql/data`) for write performance
- Shares `Handlers.cs`, `AppData.cs`, `Models.cs` from `aspnet-minimal/` via Dockerfile COPY
