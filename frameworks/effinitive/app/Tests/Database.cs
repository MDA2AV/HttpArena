using System.Collections.Concurrent;
using System.Text.Json;
using EffinitiveFramework.Core;
using EffinitiveFramework.Core.Http;
using Microsoft.Data.Sqlite;

namespace effinitive.Tests;

sealed class SqlitePool
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

public class DatabaseEndpoint : NoRequestEndpointBase<ResponseDto<DbResponseItemDto>>
{
    protected override string Method => "GET";
    protected override string Route => "/db";

    private static readonly SqlitePool? DbPool = OpenPool();

    private static SqlitePool? OpenPool()
    {
        var dbPath = "/data/benchmark.db";
        if (!File.Exists(dbPath)) return null;
        return new SqlitePool($"Data Source={dbPath};Mode=ReadOnly", Environment.ProcessorCount);
    }

    public override ValueTask<ResponseDto<DbResponseItemDto>> HandleAsync(CancellationToken ct)
    {
        if (DbPool == null)
        {
            throw new InvalidOperationException("Database not available: /data/benchmark.db was not found.");
        }

        var query = HttpContext?.Query ?? QueryCollection.Empty;
        double min = query.GetDouble("min", 10);
        double max = query.GetDouble("max", 50);

        var conn = DbPool.Rent();
        try
        {
            using var cmd = conn.CreateCommand();
            cmd.CommandText = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN @min AND @max LIMIT 50";
            cmd.Parameters.AddWithValue("@min", min);
            cmd.Parameters.AddWithValue("@max", max);

            using var reader = cmd.ExecuteReader();
            var items = new List<DbResponseItemDto>(50);

            while (reader.Read())
            {
                items.Add(new DbResponseItemDto
                {
                    Id = reader.GetInt32(0),
                    Name = reader.GetString(1),
                    Category = reader.GetString(2),
                    Price = reader.GetDouble(3),
                    Quantity = reader.GetInt32(4),
                    Active = reader.GetInt32(5) == 1,
                    Tags = JsonSerializer.Deserialize(reader.GetString(6), AppJsonContext.Default.ListString)!,
                    Rating = new RatingInfo { Score = reader.GetDouble(7), Count = reader.GetInt32(8) }
                });
            }

            return ValueTask.FromResult(new ResponseDto<DbResponseItemDto>(items, items.Count));
        }
        finally
        {
            DbPool.Return(conn);
        }
    }
}
