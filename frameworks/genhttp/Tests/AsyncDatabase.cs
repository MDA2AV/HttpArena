using System.Text.Json;

using GenHTTP.Modules.Webservices;

using Npgsql;

namespace genhttp.Tests;

public class AsyncDatabase
{
    private static readonly NpgsqlDataSource? PgDataSource = OpenPgPool();

    private static NpgsqlDataSource? OpenPgPool()
    {
        var dbUrl = Environment.GetEnvironmentVariable("DATABASE_URL");
        if (string.IsNullOrEmpty(dbUrl)) return null;
        try
        {
            var uri = new Uri(dbUrl);
            var userInfo = uri.UserInfo.Split(':');
            var connStr = $"Host={uri.Host};Port={uri.Port};Username={userInfo[0]};Password={userInfo[1]};Database={uri.AbsolutePath.TrimStart('/')};Maximum Pool Size=256;Minimum Pool Size=64;Multiplexing=true;No Reset On Close=true;Max Auto Prepare=4;Auto Prepare Min Usages=1";
            var builder = new NpgsqlDataSourceBuilder(connStr);
            return builder.Build();
        }
        catch { return null; }
    }

    [ResourceMethod]
    public async Task<ListWithCount<object>> Compute(int min = 10, int max = 50)
    {
        if (PgDataSource == null)
        {
            return new ListWithCount<object>(new List<object>());
        }

        await using var cmd = PgDataSource.CreateCommand(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT 50");
        
        cmd.Parameters.AddWithValue(min);
        cmd.Parameters.AddWithValue(max);
        
        await using var reader = await cmd.ExecuteReaderAsync();

        var items = new List<object>();
        
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
