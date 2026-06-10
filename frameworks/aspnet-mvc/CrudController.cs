using System.Text.Json;

using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Caching.Memory;

[ApiController]
[Route("crud/items")]
public sealed class CrudController : ControllerBase
{
    private static readonly MemoryCacheEntryOptions _crudCacheOpts =
        new() { AbsoluteExpirationRelativeToNow = TimeSpan.FromMilliseconds(200) };

    private static readonly JsonSerializerOptions _crudJsonOpts =
        new(JsonSerializerDefaults.Web);

    [HttpGet]
    public async Task<IResult> List(int page = 1, int limit = 10, string category = "electronics")
    {
        if (AppData.PgDataSource is null)
            return TypedResults.Problem("DB not available");

        if (page < 1) page = 1;

        if (limit < 1 || limit > 50) limit = 10;

        var offset = (page - 1) * limit;

        // Single data query. The previous COUNT(*) pass was 90%+ of PG CPU
        // because concurrent writes kept the visibility map dirty, forcing
        // heap fetches on every index-only scan. "Load more" pagination
        // (return page size, no total) is a realistic alternative that
        // removes that dominant cost.
        await using var cmd = AppData.PgDataSource.CreateCommand(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count " +
            "FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3");
        cmd.Parameters.AddWithValue(category);
        cmd.Parameters.AddWithValue(limit);
        cmd.Parameters.AddWithValue(offset);

        await using var reader = await cmd.ExecuteReaderAsync();
        var items = new List<DbResponseItemDto>();
        while (await reader.ReadAsync())
        {
            items.Add(new DbResponseItemDto
            {
                Id       = reader.GetInt32(0),
                Name     = reader.GetString(1),
                Category = reader.GetString(2),
                Price    = reader.GetInt32(3),
                Quantity = reader.GetInt32(4),
                Active   = reader.GetBoolean(5),
                Tags     = JsonSerializer.Deserialize(reader.GetString(6), AppJsonContext.Default.ListString)!,
                Rating   = new RatingInfo { Score = (int)reader.GetDouble(7), Count = reader.GetInt32(8) }
            });
        }

        return TypedResults.Json(new CrudListResponse { Items = items, Total = items.Count, Page = page, Limit = limit },
            AppJsonContext.Default.CrudListResponse);
    }

    [HttpGet("{id:int}")]
    public async Task<IResult> Read(int id)
    {
        if (AppData.PgDataSource is null)
            return TypedResults.Problem("DB not available");

        var cache = HttpContext.RequestServices.GetRequiredService<IMemoryCache>();

        var cacheKey = $"crud:{id}";

        if (AppData.RedisDb is not null)
        {
            var cachedJson = await AppData.RedisDb.StringGetAsync(cacheKey);
            if (cachedJson.HasValue)
            {
                HttpContext.Response.Headers["X-Cache"] = "HIT";
                return Results.Content((string)cachedJson!, "application/json");
            }

            var item = await FetchItemByIdAsync(id);
            if (item is null) return TypedResults.NotFound();

            var json = JsonSerializer.Serialize(item, AppJsonContext.Default.DbResponseItemDto);
            await AppData.RedisDb.StringSetAsync(cacheKey, json, TimeSpan.FromMilliseconds(200));
            HttpContext.Response.Headers["X-Cache"] = "MISS";
            return Results.Content(json, "application/json");
        }

        if (cache.TryGetValue(cacheKey, out DbResponseItemDto? cached))
        {
            HttpContext.Response.Headers["X-Cache"] = "HIT";
            return TypedResults.Json(cached, AppJsonContext.Default.DbResponseItemDto);
        }

        var dto = await FetchItemByIdAsync(id);
        if (dto is null) return TypedResults.NotFound();

        cache.Set(cacheKey, dto, _crudCacheOpts);
        HttpContext.Response.Headers["X-Cache"] = "MISS";
        return TypedResults.Json(dto, AppJsonContext.Default.DbResponseItemDto);
    }

    [HttpPost]
    public async Task<IResult> Create([FromBody] CrudItemInput input)
    {
        if (AppData.PgDataSource is null)
            return TypedResults.Problem("DB not available");

        await using var cmd = AppData.PgDataSource.CreateCommand(
            "INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) " +
            "VALUES ($1, $2, $3, $4, $5, true, '[\"bench\"]', 0, 0) " +
            "ON CONFLICT (id) DO UPDATE SET name = $2, price = $4, quantity = $5 " +
            "RETURNING id");
        cmd.Parameters.AddWithValue(input.Id);
        cmd.Parameters.AddWithValue(input.Name ?? "New Product");
        cmd.Parameters.AddWithValue(input.Category ?? "test");
        cmd.Parameters.AddWithValue(input.Price);
        cmd.Parameters.AddWithValue(input.Quantity);

        var newId = (int)(await cmd.ExecuteScalarAsync())!;
        return TypedResults.Json(
            new CrudWriteResponse { Id = newId, Name = input.Name, Category = input.Category, Price = input.Price, Quantity = input.Quantity },
            AppJsonContext.Default.CrudWriteResponse, statusCode: 201);
    }

    [HttpPut("{id:int}")]
    public async Task<IResult> Update(int id, [FromBody] CrudItemInput input)
    {
        if (AppData.PgDataSource is null)
            return TypedResults.Problem("DB not available");

        var cache = HttpContext.RequestServices.GetRequiredService<IMemoryCache>();

        await using var cmd = AppData.PgDataSource.CreateCommand(
            "UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4");
        cmd.Parameters.AddWithValue(input.Name ?? "Updated");
        cmd.Parameters.AddWithValue(input.Price);
        cmd.Parameters.AddWithValue(input.Quantity);
        cmd.Parameters.AddWithValue(id);

        var affected = await cmd.ExecuteNonQueryAsync();
        if (affected == 0) return TypedResults.NotFound();

        var cacheKey = $"crud:{id}";
        if (AppData.RedisDb is not null)
            await AppData.RedisDb.KeyDeleteAsync(cacheKey);
        else
            cache.Remove(cacheKey);
        return TypedResults.Json(
            new CrudWriteResponse { Id = id, Name = input.Name, Price = input.Price, Quantity = input.Quantity },
            AppJsonContext.Default.CrudWriteResponse);
    }

    private static async Task<DbResponseItemDto?> FetchItemByIdAsync(int id)
    {
        await using var cmd = AppData.PgDataSource!.CreateCommand(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count " +
            "FROM items WHERE id = $1 LIMIT 1");
        cmd.Parameters.AddWithValue(id);

        await using var reader = await cmd.ExecuteReaderAsync();
        if (!await reader.ReadAsync()) return null;

        return new DbResponseItemDto
        {
            Id       = reader.GetInt32(0),
            Name     = reader.GetString(1),
            Category = reader.GetString(2),
            Price    = reader.GetInt32(3),
            Quantity = reader.GetInt32(4),
            Active   = reader.GetBoolean(5),
            Tags     = JsonSerializer.Deserialize(reader.GetString(6), AppJsonContext.Default.ListString)!,
            Rating   = new RatingInfo { Score = (int)reader.GetDouble(7), Count = reader.GetInt32(8) }
        };
    }

}
