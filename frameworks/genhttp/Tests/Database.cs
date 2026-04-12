using System.Collections.Concurrent;
using System.Text.Json;

using GenHTTP.Api.Content;
using GenHTTP.Api.Protocol;

using GenHTTP.Modules.Webservices;

using Microsoft.Data.Sqlite;

namespace genhttp.Tests;

public sealed class SqlitePool
{
    private readonly ConcurrentBag<SqliteConnection> _connections = new();

    public SqlitePool(string connectionString, int size)
    {
        for (int i = 0; i < size; i++)
        {
            var conn = new SqliteConnection(connectionString);
            conn.Open();
            using var pragma = conn.CreateCommand();
            pragma.CommandText = "PRAGMA mmap_size=268435456";
            pragma.ExecuteNonQuery();
            _connections.Add(conn);
        }
    }

    public SqliteConnection Rent()
    {
        SqliteConnection? conn;
        var spin = new SpinWait();
        while (!_connections.TryTake(out conn))
            spin.SpinOnce();
        return conn;
    }

    public void Return(SqliteConnection conn) => _connections.Add(conn);
}

public class Database
{
    private static readonly SqlitePool? DbPool = OpenPool();

    private static SqlitePool? OpenPool()
    {
        var dbPath = "/data/benchmark.db";
        if (!File.Exists(dbPath)) return null;
        return new SqlitePool($"Data Source={dbPath};Mode=ReadOnly", Environment.ProcessorCount);
    }

    [ResourceMethod]
    public ListWithCount<ProcessedItem> Compute(int min = 10, int max = 50)
    {
        if (DbPool == null)
        {
            throw new ProviderException(ResponseStatus.InternalServerError, "DB not available");
        }

        var conn = DbPool.Rent();
        try
        {
            using var cmd = conn.CreateCommand();
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
                    Price = (int)reader.GetDouble(3),
                    Quantity = reader.GetInt32(4),
                    Active = reader.GetInt32(5) == 1,
                    Tags = JsonSerializer.Deserialize<List<string>>(reader.GetString(6)),
                    Rating = new RatingInfo { Score = (int)reader.GetDouble(7), Count = reader.GetInt32(8) },
                });
            }

            return new ListWithCount<ProcessedItem>(items);
        }
        finally
        {
            DbPool.Return(conn);
        }
    }

}