using System.Net.Http.Headers;
using System.Net.Http.Json;

using System.Text.Json;
using sisk;
using Microsoft.Data.Sqlite;
using Npgsql;
using Sisk.Cadente.CoreEngine;
using Sisk.Core.Http;
using Sisk.Core.Http.FileSystem;
using Sisk.Core.Routing;

var server = HttpServer.CreateBuilder()
                       .UseEngine<CadenteHttpServerEngine>()
                       .UseListeningPort(new ListeningPort(false, "0.0.0.0", 8080))
                       .UseConfiguration(c =>
                       {
                           c.EnableAutomaticResponseCompression = true;
                           c.AccessLogsStream = null;
                           c.ErrorsLogsStream = null;
                       });


Router router = new Router();

router.SetRoute(HttpFileServer.CreateServingRoute("/static", "/data/static"));

router.MapGet("/baseline11", r => new HttpResponse(Sum(r)));
router.MapPost("/baseline11", r => new HttpResponse(Sum(r)));

router.MapGet("/baseline2", r => new HttpResponse(Sum(r)));

router.MapGet("/pipeline", r => new HttpResponse("ok"));

router.MapPost("/upload", r =>
{
    var buffer = new byte[8192];

    var body = r.GetRequestStream();

    var read = 0;

    long total = 0;

    while ((read = body.Read(buffer, 0, buffer.Length)) > 0)
    {
        total += read;
    }

    return new HttpResponse(total.ToString());
});

var largeJsonBytes = LoadJson();

router.MapGet("/compression", r =>
{
    var response = new HttpResponse();

    response.Content = new ByteArrayContent(largeJsonBytes);
    response.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");

    return response;
});

var datasetItems = LoadItems();

router.MapGet("/json", r =>
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

    var result = new ListWithCount<ProcessedItem>(processed);

    return new HttpResponse
    {
        Content = JsonContent.Create(result)
    };
});

var dbConn = OpenConnection();

router.MapGet("/db", request =>
{
    var min = request.Query.TryGetValue("min", out var vmin) ? vmin.GetInteger() : 10;
    var max = request.Query.TryGetValue("max", out var vmax) ? vmax.GetInteger() : 50;

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

    return new HttpResponse
    {
        Content = JsonContent.Create(new ListWithCount<ProcessedItem>(items))
    };
});

var pgDataSource = OpenPgPool();

router.MapGet("/async-db", async (HttpRequest request) =>
{
    var min = request.Query.TryGetValue("min", out var vmin) ? vmin.GetInteger() : 10;
    var max = request.Query.TryGetValue("max", out var vmax) ? vmax.GetInteger() : 50;

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

    return new HttpResponse
    {
        Content = JsonContent.Create(new ListWithCount<object>(items))
    };
});

await server.UseRouter(router).Build().StartAsync();

return;

static string Sum(HttpRequest request)
{
    var a = 0;
    var b = 0;

    if (request.Query.TryGetValue("a", out var sa))
    {
        a = sa.GetInteger();
    }

    if (request.Query.TryGetValue("b", out var sb))
    {
        b = sb.GetInteger();
    }

    var c = 0;

    if (request.Method == HttpMethod.Post)
    {
        c = int.Parse(request.Body);
    }

    return (a + b + c).ToString();
}

static byte[]? LoadJson()
{
    var jsonOptions = new JsonSerializerOptions
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    var largePath = "/data/dataset-large.json";

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

    var datasetPath = Environment.GetEnvironmentVariable("DATASET_PATH") ?? "/data/dataset.json";

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
