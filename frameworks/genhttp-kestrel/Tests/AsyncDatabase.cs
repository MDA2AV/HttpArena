using System.Text.Json;
using genhttp.Infrastructure;
using GenHTTP.Modules.Webservices;

namespace genhttp.Tests;

public class AsyncDatabase
{

    [ResourceMethod]
    public async Task<ListWithCount<object>> Compute(int min = 10, int max = 50, int limit = 50)
    {
        var pool = Postgres.Pool;

        if (pool == null)
        {
            return new ListWithCount<object>(new List<object>());
        }

        await using var cmd = pool.CreateCommand(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3");

        cmd.Parameters.AddWithValue(min);
        cmd.Parameters.AddWithValue(max);
        cmd.Parameters.AddWithValue(limit);

        await using var reader = await cmd.ExecuteReaderAsync();

        var items = new List<object>(limit);

        while (await reader.ReadAsync())
        {
            items.Add(new
            {
                id = reader.GetInt32(0),
                name = reader.GetString(1),
                category = reader.GetString(2),
                price = reader.GetInt32(3),
                quantity = reader.GetInt32(4),
                active = reader.GetBoolean(5),
                tags = JsonSerializer.Deserialize<List<string>>(reader.GetString(6)),
                rating = new { score = reader.GetInt32(7), count = reader.GetInt32(8) },
            });
        }

        return new ListWithCount<object>(items);
    }

}
