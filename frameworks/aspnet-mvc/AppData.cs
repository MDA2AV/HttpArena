using System.Collections.Concurrent;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using Npgsql;

static class AppData
{
    public static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    public static List<DatasetItem>? DatasetItems;

    public static SqlitePool? DbPool;
    public static NpgsqlDataSource? PgDataSource;

    public static void Load()
    {
        LoadDataset();
        OpenDatabase();
        OpenPgPool();
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
            // Parse postgres:// URI into Npgsql connection string
            var uri = new Uri(dbUrl);
            var userInfo = uri.UserInfo.Split(':');
            var connStr = $"Host={uri.Host};Port={uri.Port};Username={userInfo[0]};Password={userInfo[1]};Database={uri.AbsolutePath.TrimStart('/')};Maximum Pool Size=256;Minimum Pool Size=64;Multiplexing=true;No Reset On Close=true;Max Auto Prepare=4;Auto Prepare Min Usages=1";
            var builder = new NpgsqlDataSourceBuilder(connStr);
            PgDataSource = builder.Build();
        }
        catch { }
    }

    static void OpenDatabase()
    {
        var path = "/data/benchmark.db";
        if (!File.Exists(path)) return;
        DbPool = new SqlitePool($"Data Source={path};Mode=ReadOnly", Environment.ProcessorCount);
    }
}

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
