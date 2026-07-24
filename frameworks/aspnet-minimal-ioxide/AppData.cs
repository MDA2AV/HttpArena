using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using ioxide.pg;

static class AppData
{
    public static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    public static List<DatasetItem>? DatasetItems;

    // ioxide.pg connection options. Per-reactor pools are opened from Program's OnReactorStart hook;
    // handlers run queries on the connection's reactor via HttpContext.OnReactor(...).
    public static PgOptions? PgOptions;
    public static bool PgEnabled => PgOptions is not null;

    public static void Load()
    {
        LoadDataset();
        ConfigurePg();
    }

    static void LoadDataset()
    {
        var path = Environment.GetEnvironmentVariable("DATASET_PATH") ?? "/data/dataset.json";
        if (!File.Exists(path)) return;
        DatasetItems = JsonSerializer.Deserialize<List<DatasetItem>>(File.ReadAllText(path), JsonOptions);
    }

    static void ConfigurePg()
    {
        var dbUrl = Environment.GetEnvironmentVariable("DATABASE_URL");
        if (string.IsNullOrEmpty(dbUrl)) return;
        try
        {
            var uri = new Uri(dbUrl);
            var userInfo = uri.UserInfo.Split(':');
            // ioxide.pg pools are per-reactor, so the total connection count is
            // listeners × reactors × PoolSize. Keep PoolSize modest to stay under Postgres
            // max_connections. Override with PG_POOL_SIZE.
            var poolSize = int.TryParse(Environment.GetEnvironmentVariable("PG_POOL_SIZE"), out var ps) && ps > 0 ? ps : 2;
            PgOptions = new PgOptions
            {
                Host = ResolveIPv4(uri.Host),   // ioxide.pg needs an IPv4 literal — DNS would block the reactor
                Port = (ushort)uri.Port,
                User = userInfo[0],
                Password = userInfo.Length > 1 ? userInfo[1] : null,
                Database = uri.AbsolutePath.TrimStart('/'),
                PoolSize = poolSize,
            };
        }
        catch { }
    }

    // ioxide.pg requires an IPv4 literal host; resolve once at startup.
    static string ResolveIPv4(string host)
    {
        if (IPAddress.TryParse(host, out var literal) && literal.AddressFamily == AddressFamily.InterNetwork)
            return host;
        foreach (var addr in Dns.GetHostAddresses(host))
            if (addr.AddressFamily == AddressFamily.InterNetwork)
                return addr.ToString();
        return "127.0.0.1";
    }
}
