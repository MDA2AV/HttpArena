using System.Text.Json;

using GenHTTP.Api.Content;
using GenHTTP.Api.Protocol;

using GenHTTP.Modules.Webservices;

using Microsoft.Data.Sqlite;

namespace genhttp.Tests;

public class Database
{
    private static readonly JsonSerializerOptions JsonOptions = new JsonSerializerOptions
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };
    
    private static readonly SqliteConnection? DbConn = OpenConnection();

    private static SqliteConnection? OpenConnection()
    {
        var dbPath = "/data/benchmark.db";

        if (File.Exists(dbPath))
        {
            var con = new SqliteConnection($"Data Source={dbPath};Mode=ReadOnly");
            con.Open();

            using var pragma = con.CreateCommand();
            pragma.CommandText = "PRAGMA mmap_size=268435456";
            pragma.ExecuteNonQuery();

            return con;
        }

        return null;
    }

    [ResourceMethod]
    public ListWithCount<ProcessedItem> Compute(int min = 10, int max = 50)
    {
        if (DbConn == null)
        {
            throw new ProviderException(ResponseStatus.InternalServerError, "DB not available");
        }

        using var cmd = DbConn.CreateCommand();
        cmd.CommandText = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN @min AND @max LIMIT 50";
        cmd.Parameters.AddWithValue("@min", min);
        cmd.Parameters.AddWithValue("@max", max);
        
        using var reader = cmd.ExecuteReader();
        
        var items = new List<ProcessedItem>();
        
        while (reader.Read())
        {
            items.Add(new ProcessedItem
            {
                Id = reader.GetInt32(0),
                Name = reader.GetString(1),
                Category = reader.GetString(2),
                Price = reader.GetDouble(3),
                Quantity = reader.GetInt32(4),
                Active = reader.GetInt32(5) == 1,
                Tags = JsonSerializer.Deserialize<List<string>>(reader.GetString(6)),
                Rating = new RatingInfo { Score = reader.GetDouble(7), Count = reader.GetInt32(8) },
            });
        }
        
        return new ListWithCount<ProcessedItem>(items);
    }
    
}