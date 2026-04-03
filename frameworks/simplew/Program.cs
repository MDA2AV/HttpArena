using System.Buffers;
using System.Buffers.Text;

using Microsoft.Data.Sqlite;
using Npgsql;

using SimpleW;
using SimpleW.Modules;
using SimpleW.Benchmarks;

using System.Net;
using System.Text.Json;

var options = new JsonSerializerOptions
{
    // validation fails otherwise
    PropertyNamingPolicy = JsonNamingPolicy.CamelCase
};

var server = new SimpleWServer(IPAddress.Any, 8080)
    .ConfigureJsonEngine(new SystemTextJsonEngine(_ => options))
    .Configure(o => {
        o.MaxRequestBodySize = 25 * 1024 * 1024;

        // Always beneficial socket options (see https://simplew.net/guide/performances.html#performance-oriented-configuration)
        o.TcpNoDelay = true;
        o.ReuseAddress = true;
        o.TcpKeepAlive = true;

        // Advanced tuning (platform dependent, see https://simplew.net/guide/performances.html#performance-oriented-configuration)
        o.AcceptPerCore = true;
        o.ReusePort = true; // linux only
    });

if (Directory.Exists("/data/static"))
{
    server.UseStaticFilesModule(options => {
        options.Path = "/data/static";
        options.Prefix = "/static/";
        options.AutoIndex = false;
    });
}

server.MapGet("/baseline11", (int a, int b) => a + b);
server.MapPost("/baseline11", (int a, int b, HttpSession s) => a + b + ParseInt(s.Request.Body));

server.MapGet("/baseline2", (int a, int b) => a + b);

server.MapGet("/pipeline", (HttpSession s) => s.Response.Text("ok"));

server.MapPost("/upload", (HttpSession s) => s.Request.Body.Length);

var largeJsonBytes = LoadJson();

server.MapGet("/compression", (HttpSession s) => s.Response.Body(largeJsonBytes, "application/json"));

var datasetItems = LoadItems();

server.MapGet("/json", () =>
{
    var processed = new List<ProcessedItem>(datasetItems.Count);

    foreach (var d in datasetItems)
    {
        processed.Add(new ProcessedItem
        {
            Id = d.Id, Name = d.Name, Category = d.Category,
            Price = d.Price, Quantity = d.Quantity, Active = d.Active,
            Tags = d.Tags, Rating = d.Rating,
            Total = Math.Round(d.Price * d.Quantity, 2)
        });
    }

    return new ListWithCount<ProcessedItem>(processed);
});

var dbConn = OpenConnection();

server.MapGet("/db", (int min = 10, int max = 50) =>
{
    using var cmd = dbConn.CreateCommand();
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
            Price = reader.GetDouble(3),
            Quantity = reader.GetInt32(4),
            Active = reader.GetInt32(5) == 1,
            Tags = JsonSerializer.Deserialize<List<string>>(reader.GetString(6)),
            Rating = new RatingInfo { Score = reader.GetDouble(7), Count = reader.GetInt32(8) },
        });
    }

    return new ListWithCount<ProcessedItem>(items);
});

var pgDataSource = OpenPgPool();

server.MapGet("/async-db", async (int min = 10, int max = 50) =>
{
    await using var cmd = pgDataSource.CreateCommand(
        "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT 50");
    cmd.Parameters.AddWithValue((double)min);
    cmd.Parameters.AddWithValue((double)max);
    await using var reader = await cmd.ExecuteReaderAsync();

    var items = new List<object>();

    while (await reader.ReadAsync())
    {
        items.Add(new
        {
            id = reader.GetInt32(0),
            name = reader.GetString(1),
            category = reader.GetString(2),
            price = reader.GetDouble(3),
            quantity = reader.GetInt32(4),
            active = reader.GetBoolean(5),
            tags = JsonSerializer.Deserialize<List<string>>(reader.GetString(6)),
            rating = new { score = reader.GetDouble(7), count = reader.GetInt32(8) },
        });
    }

    return new ListWithCount<object>(items);
});

server.UseWebSocketModule(ws => {
    ws.OnBinary((conn, ctx, msg) => conn.SendBinaryAsync(msg));
    ws.OnUnknown((conn, ctx, msg) => conn.SendTextAsync(msg.RawText));
});

await server.RunAsync();

return;

static byte[]? LoadJson()
{
    var jsonOptions = new JsonSerializerOptions
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };
    
    var largePath = File.Exists("/data/dataset-large.json") ? "/data/dataset-large.json" : "../../../../../data/dataset-large.json";

    if (File.Exists(largePath))
    {
        var largeItems = JsonSerializer.Deserialize<List<DatasetItem>>(File.ReadAllText(largePath), jsonOptions);

        if (largeItems != null)
        {
            var processed = largeItems.Select(d => new ProcessedItem
            {
                Id = d.Id, Name = d.Name, Category = d.Category,
                Price = d.Price, Quantity = d.Quantity, Active = d.Active,
                Tags = d.Tags, Rating = d.Rating,
                Total = Math.Round(d.Price * d.Quantity, 2)
            }).ToList();

            return JsonSerializer.SerializeToUtf8Bytes(new { items = processed, count = processed.Count }, jsonOptions);
        }
    }

    return null;
}

static List<DatasetItem>? LoadItems()
{
    var jsonOptions = new JsonSerializerOptions
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    var datasetPath = File.Exists("/data/dataset.json") ? "/data/dataset.json" : "../../../../../data/dataset.json";

    if (File.Exists(datasetPath))
    {
        return JsonSerializer.Deserialize<List<DatasetItem>>(File.ReadAllText(datasetPath), jsonOptions);
    }

    return null;
}

static SqliteConnection? OpenConnection()
{
    var dbPath = "/data/benchmark.db";

    if (File.Exists(dbPath))
    {
        var con = new SqliteConnection($"Data Source={dbPath};Mode=ReadOnly");
        con.Open();

        using var pragma = con.CreateCommand();
        pragma.CommandText = "PRAGMA mmap_size=268435456";
        pragma.ExecuteNonQuery();

        return con;
    }

    return null;
}

static NpgsqlDataSource? OpenPgPool()
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

static int ParseInt(ReadOnlySequence<byte> sequence)
{
    if (sequence.IsSingleSegment)
    {
        Utf8Parser.TryParse(sequence.FirstSpan, out int value, out _);
        return value;
    }

    Span<byte> buffer = stackalloc byte[(int)sequence.Length];
    sequence.CopyTo(buffer);
    Utf8Parser.TryParse(buffer, out int value2, out _);
    return value2;
}
