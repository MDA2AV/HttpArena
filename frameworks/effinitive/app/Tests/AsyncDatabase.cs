using System.Text.Json;
using EffinitiveFramework.Core;
using EffinitiveFramework.Core.Http;
using Npgsql;

namespace effinitive.Tests;

public class AsyncDatabaseEndpoint : NoRequestAsyncEndpointBase<ResponseDto<DbResponseItemDto>>
{
    protected override string Method => "GET";
    protected override string Route => "/async-db";

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

    public override async Task<ResponseDto<DbResponseItemDto>> HandleAsync(CancellationToken ct)
    {
        if (PgDataSource == null)
        {
            throw new InvalidOperationException("Database not available: DATABASE_URL is not configured or invalid.");
        }

        var query = HttpContext?.Query ?? QueryCollection.Empty;
        double min = query.GetDouble("min", 10);
        double max = query.GetDouble("max", 50);
        int limit = query.GetInt("limit", 50);

        await using var cmd = PgDataSource.CreateCommand(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3");

        cmd.Parameters.AddWithValue(min);
        cmd.Parameters.AddWithValue(max);
        cmd.Parameters.AddWithValue(limit);

        await using var reader = await cmd.ExecuteReaderAsync(ct);
        var items = new List<DbResponseItemDto>(limit);

        while (await reader.ReadAsync(ct))
        {
            items.Add(new DbResponseItemDto
            {
                Id = reader.GetInt32(0),
                Name = reader.GetString(1),
                Category = reader.GetString(2),
                Price = reader.GetDouble(3),
                Quantity = reader.GetInt32(4),
                Active = reader.GetBoolean(5),
                Tags = JsonSerializer.Deserialize(reader.GetString(6), AppJsonContext.Default.ListString)!,
                Rating = new RatingInfo { Score = reader.GetDouble(7), Count = reader.GetInt32(8) }
            });
        }

        return new ResponseDto<DbResponseItemDto>(items, items.Count);
    }
}
