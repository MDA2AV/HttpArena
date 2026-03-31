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
    public static byte[]? LargeJsonResponse;
    
    public static SqliteConnection? DbConnection;
    public static NpgsqlDataSource? PgDataSource;

    public static void Load()
    {
        LoadDataset();
        LoadLargeDataset();
        OpenDatabase();
        OpenPgPool();
    }

    static void LoadDataset()
    {
        var path = Environment.GetEnvironmentVariable("DATASET_PATH") ?? "data/dataset.json";
        if (!File.Exists(path)) return;
        DatasetItems = JsonSerializer.Deserialize<List<DatasetItem>>(File.ReadAllText(path), JsonOptions);
    }

    static void LoadLargeDataset()
    {
        var path = "/data/dataset-large.json";
        if (!File.Exists(path)) return;
        var items = JsonSerializer.Deserialize<List<DatasetItem>>(File.ReadAllText(path), JsonOptions);
        if (items == null) return;

        var processed = new List<ProcessedItem>(items.Count);
        foreach (var item in items)
        {
            processed.Add(new ProcessedItem
            {
                Id = item.Id, Name = item.Name, Category = item.Category,
                Price = item.Price, Quantity = item.Quantity, Active = item.Active,
                Tags = item.Tags, Rating = item.Rating,
                Total = Math.Round(item.Price * item.Quantity, 2)
            });
        }
        LargeJsonResponse = JsonSerializer.SerializeToUtf8Bytes(
            new { items = processed, count = processed.Count }, JsonOptions);
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
        DbConnection = new SqliteConnection($"Data Source={path};Mode=ReadOnly");
        DbConnection.Open();
        using var pragma = DbConnection.CreateCommand();
        pragma.CommandText = "PRAGMA mmap_size=268435456";
        pragma.ExecuteNonQuery();
    }
    
}
