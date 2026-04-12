using System.Text.Json;
using Microsoft.Data.Sqlite;
using Npgsql;

static class AppData
{
    public static List<DatasetItem>? DatasetItems;

    public static SqliteConnection? DbConnection;
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

        DatasetItems = JsonSerializer.Deserialize(File.ReadAllText(path), AppJsonContext.Default.ListDatasetItem);
    }

    static void OpenPgPool()
    {
        var dbUrl = Environment.GetEnvironmentVariable("DATABASE_URL");
        if (string.IsNullOrEmpty(dbUrl)) return;
        try
        {
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
        DbConnection = new SqliteConnection($"Data Source={path};Mode=ReadOnly");
        DbConnection.Open();
        using var pragma = DbConnection.CreateCommand();
        pragma.CommandText = "PRAGMA mmap_size=268435456";
        pragma.ExecuteNonQuery();
    }
    
}
