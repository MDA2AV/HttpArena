using Npgsql;

using StackExchange.Redis;

namespace HttpArena.Services;

/// <summary>
/// Owns the shared Postgres connection pool and the optional Redis
/// connection, both configured from environment variables. Either may be
/// unavailable; consumers must check for null.
/// </summary>
public sealed class DatabaseService
{
    public NpgsqlDataSource? Postgres { get; }

    // Optional Redis cache for the crud profile. When REDIS_URL is set,
    // ItemService uses Redis as a shared cache; otherwise it uses an
    // in-process MemoryCache. Mirrors hono-bun's pattern so frameworks
    // can be compared apples-to-apples on the same cache topology.
    public IDatabase? Redis { get; }

    public DatabaseService()
    {
        Postgres = OpenPostgres();
        Redis = OpenRedis();
    }

    private static NpgsqlDataSource? OpenPostgres()
    {
        var dbUrl = Environment.GetEnvironmentVariable("DATABASE_URL");
        if (string.IsNullOrEmpty(dbUrl)) return null;
        try
        {
            var uri = new Uri(dbUrl);
            var userInfo = uri.UserInfo.Split(':', 2);
            var maxConn = int.TryParse(Environment.GetEnvironmentVariable("DATABASE_MAX_CONN"), out var p) && p > 0 ? p : 256;

            var connStr = new NpgsqlConnectionStringBuilder
            {
                Host = uri.Host,
                Username = Uri.UnescapeDataString(userInfo[0]),
                Password = userInfo.Length > 1 ? Uri.UnescapeDataString(userInfo[1]) : null,
                Database = uri.AbsolutePath.TrimStart('/'),
                MaxPoolSize = maxConn,
                MinPoolSize = Math.Min(64, maxConn),
                Multiplexing = true,
                MaxAutoPrepare = 20
            };

            if (uri.Port > 0) connStr.Port = uri.Port;

            return new NpgsqlDataSourceBuilder(connStr.ConnectionString).Build();
        }
        catch
        {
            return null;
        }
    }

    private static IDatabase? OpenRedis()
    {
        var redisUrl = Environment.GetEnvironmentVariable("REDIS_URL");
        if (string.IsNullOrEmpty(redisUrl)) return null;
        try
        {
            // REDIS_URL is "redis://host:port" — convert to StackExchange's
            // "host:port" configuration string.
            var uri = new Uri(redisUrl);
            var config = ConfigurationOptions.Parse($"{uri.Host}:{uri.Port}");
            config.AbortOnConnectFail = false;
            return ConnectionMultiplexer.Connect(config).GetDatabase();
        }
        catch
        {
            return null;
        }
    }
}
