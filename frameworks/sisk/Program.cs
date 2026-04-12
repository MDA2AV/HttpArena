using System.Net.Http.Json;

using System.Text.Json;
using sisk;
using Npgsql;
using Sisk.Cadente.CoreEngine;
using Sisk.Core.Http;
using Sisk.Core.Routing;

var server = HttpServer.CreateBuilder()
                       .UseEngine<CadenteHttpServerEngine>()
                       .UseListeningPort(new ListeningPort(false, "0.0.0.0", 8080))
                       .UseMinimalConfiguration();

// Pre-load static files with pre-compressed variants
var staticMimeTypes = new Dictionary<string, string>
{
    [".css"] = "text/css", [".js"] = "application/javascript", [".html"] = "text/html",
    [".woff2"] = "font/woff2", [".svg"] = "image/svg+xml", [".webp"] = "image/webp", [".json"] = "application/json",
};
var staticCache = new Dictionary<string, (byte[] data, byte[]? br, byte[]? gz, string contentType)>();
if (Directory.Exists("/data/static"))
{
    foreach (var file in Directory.GetFiles("/data/static"))
    {
        var name = Path.GetFileName(file);
        if (name.EndsWith(".br") || name.EndsWith(".gz")) continue;
        var ext = Path.GetExtension(name);
        var ct = staticMimeTypes.GetValueOrDefault(ext, "application/octet-stream");
        var brPath = file + ".br";
        var gzPath = file + ".gz";
        staticCache[name] = (
            File.ReadAllBytes(file),
            File.Exists(brPath) ? File.ReadAllBytes(brPath) : null,
            File.Exists(gzPath) ? File.ReadAllBytes(gzPath) : null,
            ct
        );
    }
}

Router router = new Router();

router.MapGet("/static/<filename>", r =>
{
    var filename = r.RouteParameters["filename"].ToString();
    if (!staticCache.TryGetValue(filename, out var sf))
        return new HttpResponse(404);
    var ae = r.Headers.AcceptEncoding ?? "";
    byte[] body;
    string? encoding = null;
    if (sf.br != null && ae.Contains("br"))
    {
        body = sf.br;
        encoding = "br";
    }
    else if (sf.gz != null && ae.Contains("gzip"))
    {
        body = sf.gz;
        encoding = "gzip";
    }
    else
    {
        body = sf.data;
    }
    var resp = new HttpResponse(200);
    resp.Content = new ByteArrayContent(body);
    resp.Headers.Add("Content-Type", sf.contentType);
    if (encoding != null) resp.Headers.Add("Content-Encoding", encoding);
    return resp;
});

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

var datasetItems = LoadItems();

router.MapGet("/json/<count>", r =>
{
    int count = Math.Clamp(int.Parse(r.RouteParameters["count"].ToString()), 0, datasetItems!.Count);
    int m = 1;
    if (r.Query.TryGetValue("m", out var mStr)) { int.TryParse(mStr, out m); if (m == 0) m = 1; }
    var processed = new ProcessedItem[count];

    for (int i = 0; i < count; i++)
    {
        var d = datasetItems[i];
        processed[i] = new ProcessedItem
        {
            Id = d.Id,
            Name = d.Name,
            Category = d.Category,
            Price = d.Price,
            Quantity = d.Quantity,
            Active = d.Active,
            Tags = d.Tags,
            Rating = d.Rating,
            Total = d.Price * d.Quantity * m
        };
    }

    return new HttpResponse
    {
        Content = JsonContent.Create(new ListWithCount<ProcessedItem>(processed.ToList()))
    };
});

var pgDataSource = OpenPgPool();

router.MapGet("/async-db", async (HttpRequest request) =>
{
    var min = request.Query.TryGetValue("min", out var vmin) ? vmin.GetInteger() : 10;
    var max = request.Query.TryGetValue("max", out var vmax) ? vmax.GetInteger() : 50;
    var limit = request.Query.TryGetValue("limit", out var vlim) ? Math.Clamp(vlim.GetInteger(), 1, 50) : 50;

    await using var cmd = pgDataSource.CreateCommand(
        "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3");
    cmd.Parameters.AddWithValue(min);
    cmd.Parameters.AddWithValue(max);
    cmd.Parameters.AddWithValue(limit);
    await using var reader = await cmd.ExecuteReaderAsync();

    var items = new List<object>();

    while (await reader.ReadAsync())
    {
        items.Add(new
        {
            id = reader.GetInt32(0),
            name = reader.GetString(1),
            category = reader.GetString(2),
            price = reader.GetInt32(3),
            quantity = reader.GetInt32(4),
            active = reader.GetBoolean(5),
            tags = JsonSerializer.Deserialize<List<string>>(reader.GetString(6)),
            rating = new { score = reader.GetInt32(7), count = reader.GetInt32(8) },
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
    var a = request.Query["a"].MaybeNullOrEmpty()?.GetInteger() ?? 0;
    var b = request.Query["b"].MaybeNullOrEmpty()?.GetInteger() ?? 0;

    var c = 0;

    if (request.Method == HttpMethod.Post)
    {
        c = int.Parse(request.Body);
    }

    return (a + b + c).ToString();
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

