using System.Text.Json;
using Npgsql;
using StackExchange.Redis;

static class AppData
{
    public static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    public static List<DatasetItem>? DatasetItems;

    public static NpgsqlDataSource? PgDataSource;

    // Optional Redis cache for the crud profile. When REDIS_URL is set,
    // crud handlers use Redis as a shared cache; otherwise they use the
    // in-process IMemoryCache. Mirrors hono-bun's pattern so frameworks
    // can be compared apples-to-apples on the same cache topology.
    public static IDatabase? RedisDb;

    public static void Load()
    {
        LoadDataset();
        OpenPgPool();
        OpenRedis();
    }

    static void LoadDataset()
    {
        var path = Environment.GetEnvironmentVariable("DATASET_PATH") ?? "/data/dataset.json";
        if (!File.Exists(path)) return;
        DatasetItems = JsonSerializer.Deserialize<List<DatasetItem>>(File.ReadAllText(path), JsonOptions);
    }

    static void OpenPgPool()
    {
        var dbUrl = Environment.GetEnvironmentVariable("DATABASE_URL");
        if (string.IsNullOrEmpty(dbUrl)) return;
        try
        {
            var uri = new Uri(dbUrl);
            var userInfo = uri.UserInfo.Split(':');
            var maxConn = int.TryParse(Environment.GetEnvironmentVariable("DATABASE_MAX_CONN"), out var p) && p > 0 ? p : 256;
            var minConn = Math.Min(64, maxConn);
            var connStr = $"Host={uri.Host};Port={uri.Port};Username={userInfo[0]};Password={userInfo[1]};Database={uri.AbsolutePath.TrimStart('/')};Maximum Pool Size={maxConn};Minimum Pool Size={minConn};Multiplexing=true;No Reset On Close=true;Max Auto Prepare=20;Auto Prepare Min Usages=1";
            var builder = new NpgsqlDataSourceBuilder(connStr);
            PgDataSource = builder.Build();
        }
        catch { }
    }

    static void OpenRedis()
    {
        var redisUrl = Environment.GetEnvironmentVariable("REDIS_URL");
        if (string.IsNullOrEmpty(redisUrl)) return;
        try
        {
            // REDIS_URL is "redis://host:port" — convert to StackExchange's
            // "host:port" configuration string.
            var uri = new Uri(redisUrl);
            var config = ConfigurationOptions.Parse($"{uri.Host}:{uri.Port}");
            config.AbortOnConnectFail = false;
            var muxer = ConnectionMultiplexer.Connect(config);
            RedisDb = muxer.GetDatabase();
        }
        catch { }
    }
}
