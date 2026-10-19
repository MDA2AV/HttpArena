using System.Text.Json;

using Npgsql;

namespace HttpArena.Data;

/// <summary>
/// Price range queries against the Postgres `items` table for /async-db.
/// </summary>
public sealed class ItemService(NpgsqlDataSource dataSource)
{
    public async Task<ItemsResponse<Item>> QueryAsync(int min, int max, int limit, CancellationToken cancellationToken)
    {
        await using var command = dataSource.CreateCommand(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count " +
            "FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3");

        command.Parameters.Add(new NpgsqlParameter<int> { TypedValue = min });
        command.Parameters.Add(new NpgsqlParameter<int> { TypedValue = max });
        command.Parameters.Add(new NpgsqlParameter<int> { TypedValue = limit });

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        var items = new List<Item>(limit);

        while (await reader.ReadAsync(cancellationToken))
        {
            items.Add(new Item
            {
                Id = reader.GetInt32(0),
                Name = reader.GetString(1),
                Category = reader.GetString(2),
                Price = reader.GetInt32(3),
                Quantity = reader.GetInt32(4),
                Active = reader.GetBoolean(5),
                Tags = JsonSerializer.Deserialize(reader.GetString(6), AppJsonContext.Default.ListString) ?? [],
                Rating = new RatingInfo { Score = reader.GetInt32(7), Count = reader.GetInt32(8) }
            });
        }

        return new ItemsResponse<Item>(items, items.Count);
    }
}
