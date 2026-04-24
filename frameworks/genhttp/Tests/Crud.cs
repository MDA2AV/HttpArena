using System.Collections.Concurrent;
using System.Text.Json;
using GenHTTP.Api.Content;
using GenHTTP.Api.Protocol;
using genhttp.Infrastructure;
using GenHTTP.Modules.Reflection;
using GenHTTP.Modules.Webservices;
using Npgsql;

namespace genhttp.Tests;

public class Crud
{
    private static readonly NpgsqlDataSource? PgDataSource = Postgres.OpenPool();

    private static readonly ConcurrentDictionary<int, ProcessedItem> Cache = new(Environment.ProcessorCount, 50_000);

    [ResourceMethod]
    public async Task<CrudListResponse> List(string category = "electronics", int page = 1, int limit = 10)
    {
        if (page < 1) page = 1;
        if (limit is < 1 or > 50) limit = 10;

        var offset = (page - 1) * limit;

        await using var cmd = PgDataSource.CreateCommand(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count " +
            "FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3");

        cmd.Parameters.AddWithValue(category);
        cmd.Parameters.AddWithValue(limit);
        cmd.Parameters.AddWithValue(offset);

        await using var reader = await cmd.ExecuteReaderAsync();

        var items = new List<ProcessedItem>();

        while (await reader.ReadAsync())
        {
            items.Add(new ProcessedItem
            {
                Id       = reader.GetInt32(0),
                Name     = reader.GetString(1),
                Category = reader.GetString(2),
                Price    = reader.GetInt32(3),
                Quantity = reader.GetInt32(4),
                Active   = reader.GetBoolean(5),
                Tags     = JsonSerializer.Deserialize<List<string>>(reader.GetString(6)),
                Rating   = new RatingInfo { Score = (int)reader.GetDouble(7), Count = reader.GetInt32(8) }
            });
        }

        return new CrudListResponse { Items = items, Total = items.Count, Page = page, Limit = limit };
    }

    [ResourceMethod(":id")]
    public async ValueTask<Result<ProcessedItem>> Get(int id)
    {
        if (Cache.TryGetValue(id, out var cached))
        {
            return new Result<ProcessedItem>(cached).Header("X-Cache", "HIT");
        }

        var item = await FetchItemByIdAsync(id);

        if (item == null)
        {
            throw new ProviderException(ResponseStatus.NotFound, $"Item with ID {id} does not exist");
        }

        Cache.TryAdd(id, item);

        return new Result<ProcessedItem>(item).Header("X-Cache", "MISS");
    }

    [ResourceMethod(RequestMethod.Post)]
    public async Task<Result<CrudItem>> Create(CrudItem item)
    {
        await using var cmd = PgDataSource.CreateCommand(
            "INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) " +
            "VALUES ($1, $2, $3, $4, $5, true, '[\"bench\"]', 0, 0) " +
            "ON CONFLICT (id) DO UPDATE SET name = $2, price = $4, quantity = $5 " +
            "RETURNING id");

        cmd.Parameters.AddWithValue(item.Id);
        cmd.Parameters.AddWithValue(item.Name ?? "New Product");
        cmd.Parameters.AddWithValue(item.Category ?? "test");
        cmd.Parameters.AddWithValue(item.Price);
        cmd.Parameters.AddWithValue(item.Quantity);

        item.Id = (int)(await cmd.ExecuteScalarAsync())!;

        return new Result<CrudItem>(item).Status(ResponseStatus.Created);
    }

    [ResourceMethod(RequestMethod.Put, ":id")]
    public async Task<CrudItem> Update(int id, CrudItem item)
    {
        await using var cmd = PgDataSource.CreateCommand(
            "UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4");

        cmd.Parameters.AddWithValue(item.Name ?? "Updated");
        cmd.Parameters.AddWithValue(item.Price);
        cmd.Parameters.AddWithValue(item.Quantity);
        cmd.Parameters.AddWithValue(id);

        var affected = await cmd.ExecuteNonQueryAsync();

        if (affected == 0)
        {
            throw new ProviderException(ResponseStatus.NotFound, $"Item with ID {id} does not exist");
        }

        Cache.TryRemove(id, out _);

        return item;
    }

    private static async Task<ProcessedItem?> FetchItemByIdAsync(int id)
    {
        await using var cmd = PgDataSource!.CreateCommand(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count " +
            "FROM items WHERE id = $1 LIMIT 1");

        cmd.Parameters.AddWithValue(id);

        await using var reader = await cmd.ExecuteReaderAsync();
        if (!await reader.ReadAsync()) return null;

        return new ProcessedItem()
        {
            Id       = reader.GetInt32(0),
            Name     = reader.GetString(1),
            Category = reader.GetString(2),
            Price    = reader.GetInt32(3),
            Quantity = reader.GetInt32(4),
            Active   = reader.GetBoolean(5),
            Tags     = JsonSerializer.Deserialize<List<string>>(reader.GetString(6)),
            Rating   = new RatingInfo { Score = (int)reader.GetDouble(7), Count = reader.GetInt32(8) }
        };
    }

}
