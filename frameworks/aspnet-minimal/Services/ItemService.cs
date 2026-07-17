using System.Text.Json;

using HttpArena.Types;

using Microsoft.Extensions.Caching.Memory;

using Npgsql;

namespace HttpArena.Services;

/// <summary>
/// Item queries against Postgres: the /async-db range query plus a
/// realistic CRUD API with paginated list, cached single-item read,
/// create, and update. Cache-aside on single-item reads with 200ms TTL,
/// invalidated on update. List queries always hit Postgres.
/// </summary>
public sealed class ItemService
{
    private static readonly TimeSpan CacheTtl = TimeSpan.FromMilliseconds(200);

    private static readonly MemoryCacheEntryOptions CacheEntryOptions =
        new() { AbsoluteExpirationRelativeToNow = CacheTtl };

    private readonly DatabaseService _database;

    // In-process fallback cache; only constructed when Redis is not configured.
    private readonly MemoryCache? _cache;

    public ItemService(DatabaseService database)
    {
        _database = database;

        if (database.Redis is null)
        {
            _cache = new MemoryCache(new MemoryCacheOptions());
        }
    }

    public bool IsAvailable => _database.Postgres is not null;

    /// <summary>
    /// Range query for /async-db: items with price between
    /// <paramref name="min"/> and <paramref name="max"/>.
    /// </summary>
    public async Task<ItemsResponse<Item>> QueryAsync(double min, double max, int limit)
    {
        limit = Math.Clamp(limit, 1, 50);

        await using var cmd = _database.Postgres!.CreateCommand(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3");

        cmd.Parameters.AddWithValue(min);
        cmd.Parameters.AddWithValue(max);
        cmd.Parameters.AddWithValue(limit);

        await using var reader = await cmd.ExecuteReaderAsync();

        var items = new List<Item>(limit);

        while (await reader.ReadAsync())
        {
            items.Add(ReadItem(reader));
        }

        return new ItemsResponse<Item>(items, items.Count);
    }

    /// <summary>
    /// Paginated list by category (always DB, never cached). Out-of-range
    /// paging inputs fall back to page 1 / limit 10.
    /// </summary>
    public async Task<CrudListResponse> ListAsync(string? category, int page, int limit)
    {
        if (string.IsNullOrEmpty(category)) category = "electronics";
        if (page < 1) page = 1;
        if (limit < 1 || limit > 50) limit = 10;
        var offset = (page - 1) * limit;

        // Single data query. A COUNT(*) pass was 90%+ of PG CPU because
        // concurrent writes kept the visibility map dirty, forcing heap
        // fetches on every index-only scan. "Load more" pagination
        // (return page size, no total) is a realistic alternative that
        // removes that dominant cost.
        await using var cmd = _database.Postgres!.CreateCommand(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count " +
            "FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3");
        cmd.Parameters.AddWithValue(category);
        cmd.Parameters.AddWithValue(limit);
        cmd.Parameters.AddWithValue(offset);

        await using var reader = await cmd.ExecuteReaderAsync();
        var items = new List<Item>();
        while (await reader.ReadAsync())
        {
            items.Add(ReadItem(reader));
        }

        return new CrudListResponse { Items = items, Total = items.Count, Page = page, Limit = limit };
    }

    /// <summary>
    /// Single item read, cached with 200ms TTL. Redis when available (the
    /// cache stores pre-serialized JSON so the HIT path skips a
    /// Serialize+Deserialize round trip); else in-process MemoryCache
    /// (caches the typed DTO). Returns null when the item does not exist.
    /// </summary>
    public async Task<CachedItemResult?> ReadAsync(int id)
    {
        var cacheKey = CacheKey(id);

        if (_database.Redis is not null)
        {
            var cachedJson = await _database.Redis.StringGetAsync(cacheKey);
            if (cachedJson.HasValue)
            {
                return new CachedItemResult(null, (string)cachedJson!, CacheHit: true);
            }

            var item = await FetchItemByIdAsync(id);
            if (item is null) return null;

            var json = JsonSerializer.Serialize(item, AppJsonContext.Default.Item);
            await _database.Redis.StringSetAsync(cacheKey, json, CacheTtl);
            return new CachedItemResult(null, json, CacheHit: false);
        }

        if (_cache!.TryGetValue(cacheKey, out Item? cached))
        {
            return new CachedItemResult(cached, null, CacheHit: true);
        }

        var dto = await FetchItemByIdAsync(id);
        if (dto is null) return null;

        _cache.Set(cacheKey, dto, CacheEntryOptions);
        return new CachedItemResult(dto, null, CacheHit: false);
    }

    /// <summary>
    /// Creates an item (upsert on id conflict).
    /// </summary>
    public async Task<CrudWriteResponse> CreateAsync(CrudItemInput input)
    {
        await using var cmd = _database.Postgres!.CreateCommand(
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
        return new CrudWriteResponse { Id = newId, Name = input.Name, Category = input.Category, Price = input.Price, Quantity = input.Quantity };
    }

    /// <summary>
    /// Updates an item and invalidates its cache entry. Returns null when
    /// the item does not exist.
    /// </summary>
    public async Task<CrudWriteResponse?> UpdateAsync(int id, CrudItemInput input)
    {
        await using var cmd = _database.Postgres!.CreateCommand(
            "UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4");
        cmd.Parameters.AddWithValue(input.Name ?? "Updated");
        cmd.Parameters.AddWithValue(input.Price);
        cmd.Parameters.AddWithValue(input.Quantity);
        cmd.Parameters.AddWithValue(id);

        var affected = await cmd.ExecuteNonQueryAsync();
        if (affected == 0) return null;

        var cacheKey = CacheKey(id);
        if (_database.Redis is not null)
        {
            await _database.Redis.KeyDeleteAsync(cacheKey);
        }
        else
        {
            _cache!.Remove(cacheKey);
        }

        return new CrudWriteResponse { Id = id, Name = input.Name, Price = input.Price, Quantity = input.Quantity };
    }

    private async Task<Item?> FetchItemByIdAsync(int id)
    {
        await using var cmd = _database.Postgres!.CreateCommand(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count " +
            "FROM items WHERE id = $1 LIMIT 1");
        cmd.Parameters.AddWithValue(id);

        await using var reader = await cmd.ExecuteReaderAsync();
        if (!await reader.ReadAsync()) return null;

        return ReadItem(reader);
    }

    private static Item ReadItem(NpgsqlDataReader reader) => new()
    {
        Id = reader.GetInt32(0),
        Name = reader.GetString(1),
        Category = reader.GetString(2),
        Price = reader.GetInt32(3),
        Quantity = reader.GetInt32(4),
        Active = reader.GetBoolean(5),
        Tags = JsonSerializer.Deserialize(reader.GetString(6), AppJsonContext.Default.ListString)!,
        Rating = new RatingInfo { Score = reader.GetInt32(7), Count = reader.GetInt32(8) }
    };

    private static string CacheKey(int id) => $"crud:{id}";
}
