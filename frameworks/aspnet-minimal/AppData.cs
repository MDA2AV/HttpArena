using System.Text.Json;
using Npgsql;

static class AppData
{
    public static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    public static List<DatasetItem>? DatasetItems;

    public static NpgsqlDataSource? PgDataSource;

    public static void Load()
    {
        LoadDataset();
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
            var uri = new Uri(dbUrl);
            var userInfo = uri.UserInfo.Split(':');
            var connStr = $"Host={uri.Host};Port={uri.Port};Username={userInfo[0]};Password={userInfo[1]};Database={uri.AbsolutePath.TrimStart('/')};Maximum Pool Size=256;Minimum Pool Size=64;Multiplexing=true;No Reset On Close=true;Max Auto Prepare=4;Auto Prepare Min Usages=1";
            var builder = new NpgsqlDataSourceBuilder(connStr);
            PgDataSource = builder.Build();
        }
        catch { }
    }
}
