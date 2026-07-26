using System.Buffers;
using System.Buffers.Text;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.Extensions.Caching.Memory;
using ioxide.pg;
using ioxide.Kestrel;


[JsonSerializable(typeof(ResponseDto<ProcessedItem>))]
[JsonSerializable(typeof(ResponseDto<DbResponseItemDto>))]
[JsonSerializable(typeof(DbResponseItemDto))]
[JsonSerializable(typeof(ProcessedItem))]
[JsonSerializable(typeof(RatingInfo))]
[JsonSerializable(typeof(List<string>))]
[JsonSerializable(typeof(CrudListResponse))]
[JsonSerializable(typeof(CrudWriteResponse))]
[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
partial class AppJsonContext : JsonSerializerContext { }

static class Handlers
{
    public static string Sum(int a, int b) => (a + b).ToString();

    public static async ValueTask<string> SumBody(int a, int b, HttpRequest req)
    {
        using var reader = new StreamReader(req.Body);
        return (a + b + int.Parse(await reader.ReadToEndAsync())).ToString();
    }

    public static string Text() => "ok";

    public static async ValueTask<string> Upload(HttpRequest req)
    {
        long size = 0;
        var buffer = ArrayPool<byte>.Shared.Rent(65536);
        try
        {
            int read;
            while ((read = await req.Body.ReadAsync(buffer.AsMemory(0, buffer.Length))) > 0)
            {
                size += read;
            }
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
        }

        return size.ToString();
    }

    public static Results<JsonHttpResult<ResponseDto<ProcessedItem>>, ProblemHttpResult> Json(int count, HttpRequest req)
    {
        var source = AppData.DatasetItems;
        if (source == null)
            return TypedResults.Problem("Dataset not loaded");

        if (count > source.Count) count = source.Count;
        if (count < 0) count = 0;

        int m = 1;
        if (req.Query.TryGetValue("m", out var mVal) && int.TryParse(mVal, out var pm)) m = pm;

        var items = new ProcessedItem[count];

        for (int i = 0; i < count; i++)
        {
            var item = source[i];
            items[i] = new ProcessedItem
            {
                Id = item.Id,
                Name = item.Name,
                Category = item.Category,
                Price = item.Price,
                Quantity = item.Quantity,
                Active = item.Active,
                Tags = item.Tags,
                Rating = item.Rating,
                Total = item.Price * item.Quantity * m
            };
        }

        return TypedResults.Json(new ResponseDto<ProcessedItem>(items, count), AppJsonContext.Default.ResponseDtoProcessedItem);
    }

    // ── ioxide.pg row mapping ───────────────────────────────────────────
    // ioxide.pg returns text columns as ReadOnlySpan<byte> by index. PgRow is a ref struct valid only inside
    // the callback, so the DTO is materialized here.
    static DbResponseItemDto MapItem(in PgRow row) => new DbResponseItemDto
    {
        Id       = ParseInt(row.Field(0)),
        Name     = Encoding.UTF8.GetString(row.Field(1)),
        Category = Encoding.UTF8.GetString(row.Field(2)),
        Price    = (int)ParseDouble(row.Field(3)),
        Quantity = ParseInt(row.Field(4)),
        Active   = row.Field(5).SequenceEqual("t"u8),
        Tags     = JsonSerializer.Deserialize(row.Field(6), AppJsonContext.Default.ListString)!,
        Rating   = new RatingInfo { Score = (int)ParseDouble(row.Field(7)), Count = ParseInt(row.Field(8)) }
    };

    static int ParseInt(ReadOnlySpan<byte> s) => Utf8Parser.TryParse(s, out int v, out _) ? v : 0;
    static double ParseDouble(ReadOnlySpan<byte> s) => Utf8Parser.TryParse(s, out double v, out _) ? v : 0;
    static int AffectedRows(string tag)
    {
        int sp = tag.LastIndexOf(' ');
        return sp >= 0 && int.TryParse(tag.AsSpan(sp + 1), out var n) ? n : 0;
    }

    // GET /async-db — price-range query, on the connection's reactor via ioxide.pg.
    public static async Task<IResult> AsyncDatabase(HttpContext ctx)
    {
        if (!AppData.PgEnabled)
            return TypedResults.Problem("DB not available");

        var query = ctx.Request.Query;
        double min = 10, max = 50;
        int limit = 50;
        if (query.TryGetValue("min", out var minVal) && double.TryParse(minVal, out var pmin)) min = pmin;
        if (query.TryGetValue("max", out var maxVal) && double.TryParse(maxVal, out var pmax)) max = pmax;
        if (query.TryGetValue("limit", out var limVal) && int.TryParse(limVal, out var plim)) limit = Math.Clamp(plim, 1, 50);

        var items = await ctx.OnReactor(async r =>
        {
            var pool = r.GetService<PgPool>();
            var list = new List<DbResponseItemDto>(limit);
            var args = new[]
            {
                PgParam.Text(min.ToString(CultureInfo.InvariantCulture)),
                PgParam.Text(max.ToString(CultureInfo.InvariantCulture)),
                PgParam.Int(limit),
            };
            await pool.QueryAsync(
                "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3",
                args, row => list.Add(MapItem(row)));
            return list;
        });
        // Write the body in-handler. Returning TypedResults.Json here yields an empty body: after an
        // OnReactor query the minimal-API result-execution step writes nothing for these wrapper types,
        // whereas WriteAsJsonAsync in-handler streams reliably via the source-gen JsonTypeInfo.
        await ctx.Response.WriteAsJsonAsync(new ResponseDto<DbResponseItemDto>(items, items.Count), AppJsonContext.Default.ResponseDtoDbResponseItemDto);
        return Results.Empty;
    }

    // ── CRUD handlers ──────────────────────────────────────────────────

    private static readonly MemoryCacheEntryOptions _crudCacheOpts =
        new() { AbsoluteExpirationRelativeToNow = TimeSpan.FromMilliseconds(200) };

    private static readonly JsonSerializerOptions _crudJsonOpts =
        new(JsonSerializerDefaults.Web);

    // GET /crud/items?category=X&page=N&limit=M — paginated list (always DB, never cached)
    public static async Task<IResult> CrudList(HttpContext ctx)
    {
        if (!AppData.PgEnabled)
            return TypedResults.Problem("DB not available");

        var query = ctx.Request.Query;
        var category = query["category"].ToString();
        if (string.IsNullOrEmpty(category)) category = "electronics";
        int.TryParse(query["page"], out var page);
        if (page < 1) page = 1;
        int.TryParse(query["limit"], out var limit);
        if (limit < 1 || limit > 50) limit = 10;
        var offset = (page - 1) * limit;

        var items = await ctx.OnReactor(async r =>
        {
            var pool = r.GetService<PgPool>();
            var list = new List<DbResponseItemDto>();
            var args = new[] { PgParam.Text(category), PgParam.Int(limit), PgParam.Int(offset) };
            await pool.QueryAsync(
                "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3",
                args, row => list.Add(MapItem(row)));
            return list;
        });
        // In-handler write (see AsyncDatabase): returning the IResult drops the body for this wrapper type.
        await ctx.Response.WriteAsJsonAsync(new CrudListResponse { Items = items, Total = items.Count, Page = page, Limit = limit },
            AppJsonContext.Default.CrudListResponse);
        return Results.Empty;
    }

    // GET /crud/items/{id} — single item, cached in-process (IMemoryCache) with 200ms TTL.
    public static async Task<IResult> CrudRead(int id, IMemoryCache cache, HttpContext ctx)
    {
        if (!AppData.PgEnabled)
            return TypedResults.Problem("DB not available");

        var cacheKey = $"crud:{id}";

        if (cache.TryGetValue(cacheKey, out DbResponseItemDto? cached))
        {
            ctx.Response.Headers["X-Cache"] = "HIT";
            return TypedResults.Json(cached, AppJsonContext.Default.DbResponseItemDto);
        }

        var dto = await FetchItemByIdAsync(ctx, id);
        if (dto is null) return TypedResults.NotFound();

        cache.Set(cacheKey, dto, _crudCacheOpts);
        ctx.Response.Headers["X-Cache"] = "MISS";
        return TypedResults.Json(dto, AppJsonContext.Default.DbResponseItemDto);
    }

    // Single-item fetch on the connection's reactor.
    private static Task<DbResponseItemDto?> FetchItemByIdAsync(HttpContext ctx, int id)
    {
        return ctx.OnReactor(async r =>
        {
            var pool = r.GetService<PgPool>();
            DbResponseItemDto? dto = null;
            var args = new[] { PgParam.Int(id) };
            await pool.QueryAsync(
                "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE id = $1 LIMIT 1",
                args, row => dto = MapItem(row));
            return dto;
        });
    }

    // POST /crud/items — create item, return 201
    public static async Task<IResult> CrudCreate(HttpRequest req, HttpContext ctx)
    {
        if (!AppData.PgEnabled)
            return TypedResults.Problem("DB not available");

        using var sr = new StreamReader(req.Body);
        var body = await sr.ReadToEndAsync();
        var input = JsonSerializer.Deserialize<CrudItemInput>(body, _crudJsonOpts);
        if (input is null)
            return TypedResults.BadRequest();

        var newId = await ctx.OnReactor(async r =>
        {
            var pool = r.GetService<PgPool>();
            var args = new[]
            {
                PgParam.Int(input.Id),
                PgParam.Text(input.Name ?? "New Product"),
                PgParam.Text(input.Category ?? "test"),
                PgParam.Int(input.Price),
                PgParam.Int(input.Quantity),
            };
            var result = await pool.QueryAsync(
                "INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) " +
                "VALUES ($1, $2, $3, $4, $5, true, '[\"bench\"]', 0, 0) " +
                "ON CONFLICT (id) DO UPDATE SET name = $2, price = $4, quantity = $5 RETURNING id", args);
            return int.TryParse(result.Value, out var v) ? v : input.Id;
        });

        return TypedResults.Json(
            new CrudWriteResponse { Id = newId, Name = input.Name, Category = input.Category, Price = input.Price, Quantity = input.Quantity },
            AppJsonContext.Default.CrudWriteResponse, statusCode: 201);
    }

    // PUT /crud/items/{id} — update item, invalidate cache
    public static async Task<IResult> CrudUpdate(int id, HttpRequest req, IMemoryCache cache, HttpContext ctx)
    {
        if (!AppData.PgEnabled)
            return TypedResults.Problem("DB not available");

        using var sr = new StreamReader(req.Body);
        var body = await sr.ReadToEndAsync();
        var input = JsonSerializer.Deserialize<CrudItemInput>(body, _crudJsonOpts);
        if (input is null)
            return TypedResults.BadRequest();

        var affected = await ctx.OnReactor(async r =>
        {
            var pool = r.GetService<PgPool>();
            var args = new[]
            {
                PgParam.Text(input.Name ?? "Updated"),
                PgParam.Int(input.Price),
                PgParam.Int(input.Quantity),
                PgParam.Int(id),
            };
            var result = await pool.QueryAsync("UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4", args);
            return AffectedRows(result.CommandTag);
        });

        if (affected == 0) return TypedResults.NotFound();

        cache.Remove($"crud:{id}");
        return TypedResults.Json(
            new CrudWriteResponse { Id = id, Name = input.Name, Price = input.Price, Quantity = input.Quantity },
            AppJsonContext.Default.CrudWriteResponse);
    }
}

record CrudItemInput(int Id, string? Name, string? Category, int Price, int Quantity);
