using System.Buffers;
using System.Buffers.Text;
using System.Collections.Concurrent;
using System.IO.Compression;
using System.Net;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;

using Npgsql;

using SimpleW;
using SimpleW.Modules;
using SimpleW.Benchmarks;

var jsonOptions = new JsonSerializerOptions(JsonSerializerDefaults.Web);
var datasetItems = LoadItems();
var pgDataSource = OpenPgPool();
var crudCache = new ConcurrentDictionary<int, CrudCacheEntry>();

var plainServer = CreateServer(8080);
var tlsServer = CreateTlsServer(8081);

if (tlsServer is null)
{
    await plainServer.RunAsync();
}
else
{
    await Task.WhenAll(plainServer.RunAsync(), tlsServer.RunAsync());
}

return;

SimpleWServer CreateServer(int port, SslContext? sslContext = null)
{
    var server = new SimpleWServer(IPAddress.Any, port)
        .ConfigureJsonEngine(new SystemTextJsonEngine(_ => jsonOptions))
        .Configure(o => {
            o.MaxRequestBodySize = 25 * 1024 * 1024;
            o.TcpNoDelay = true;
            o.ReuseAddress = true;
            o.TcpKeepAlive = true;
            o.AcceptPerCore = true;
            o.ReusePort = true;
        });

    if (sslContext is not null)
    {
        server.UseHttps(sslContext);
    }

    ConfigureRoutes(server);
    return server;
}

SimpleWServer? CreateTlsServer(int port)
{
    var certPath = Environment.GetEnvironmentVariable("TLS_CERT") ?? "/certs/server.crt";
    var keyPath = Environment.GetEnvironmentVariable("TLS_KEY") ?? "/certs/server.key";

    if (!File.Exists(certPath) || !File.Exists(keyPath))
    {
        return null;
    }

    var certificate = X509Certificate2.CreateFromPemFile(certPath, keyPath);
    var sslContext = new SslContext(
        SslProtocols.Tls12 | SslProtocols.Tls13,
        certificate,
        clientCertificateRequired: false,
        checkCertificateRevocation: false);

    return CreateServer(port, sslContext);
}

void ConfigureRoutes(SimpleWServer server)
{
    if (Directory.Exists("/data/static"))
    {
        server.UseStaticFilesModule(options => {
            options.Path = "/data/static";
            options.Prefix = "/static/";
            options.AutoIndex = false;
        });
    }

    server.MapGet("/baseline11", (int a, int b, HttpSession s) => Text(s, a + b));
    server.MapPost("/baseline11", (int a, int b, HttpSession s) => Text(s, a + b + ParseInt(s.Request.Body)));

    server.MapGet("/baseline2", (int a, int b, HttpSession s) => Text(s, a + b));

    server.MapGet("/pipeline", (HttpSession s) => s.Response.Text("ok"));

    server.MapPost("/upload", (HttpSession s) => Text(s, s.Request.Body.Length));

    server.MapGet("/json/:count", (HttpSession s) =>
        JsonResponse(s, GetRouteInt(s, "count", 50), GetQueryInt(s, "m", 1)));

    // Kept for old probes and ad-hoc checks; official tests use /json/:count.
    server.MapGet("/json", (HttpSession s) => JsonResponse(s, 50, GetQueryInt(s, "m", 1)));

    server.MapGet("/async-db", async (HttpSession s) => await AsyncDatabase(s));

    server.MapGet("/crud/items", async (HttpSession s) => await CrudList(s));
    server.MapGet("/crud/items/:id", async (HttpSession s) => await CrudRead(s));
    server.MapPost("/crud/items", async (HttpSession s) => await CrudCreate(s));
    server.Map("PUT", "/crud/items/:id", async (HttpSession s) => await CrudUpdate(s));

    server.UseWebSocketModule(ws => {
        ws.OnBinary((conn, ctx, msg) => conn.SendBinaryAsync(msg));
        ws.OnUnknown((conn, ctx, msg) => conn.SendTextAsync(msg.RawText));
    });
}

HttpResponse Text(HttpSession session, long value) => session.Response.Text(value.ToString());

HttpResponse JsonResponse(HttpSession session, int count, int multiplier)
{
    if (datasetItems is null)
    {
        return session.Response.InternalServerError("Dataset not loaded");
    }

    count = Math.Clamp(count, 0, datasetItems.Count);
    var processed = new List<ProcessedItem>(count);

    for (var i = 0; i < count; i++)
    {
        var item = datasetItems[i];
        processed.Add(new ProcessedItem
        {
            Id = item.Id,
            Name = item.Name,
            Category = item.Category,
            Price = item.Price,
            Quantity = item.Quantity,
            Active = item.Active,
            Tags = item.Tags,
            Rating = item.Rating,
            Total = (long)item.Price * item.Quantity * multiplier
        });
    }

    return session.Response
                  .Json(new ListWithCount<ProcessedItem>(processed))
                  .Compression(HttpResponse.ResponseCompressionMode.Auto, 0, CompressionLevel.Fastest);
}

async Task<HttpResponse> AsyncDatabase(HttpSession session)
{
    if (pgDataSource is null)
    {
        return session.Response.Json(new ListWithCount<DbItem>([]));
    }

    var min = GetQueryInt(session, "min", 10);
    var max = GetQueryInt(session, "max", 50);
    var limit = Math.Clamp(GetQueryInt(session, "limit", 50), 1, 50);

    await using var cmd = pgDataSource.CreateCommand(
        "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count " +
        "FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3");

    cmd.Parameters.AddWithValue(min);
    cmd.Parameters.AddWithValue(max);
    cmd.Parameters.AddWithValue(limit);
    cmd.CommandTimeout = 2;

    await using var reader = await cmd.ExecuteReaderAsync(session.RequestAborted);

    var items = new List<DbItem>(limit);

    while (await reader.ReadAsync(session.RequestAborted))
    {
        items.Add(ReadDbItem(reader));
    }

    return session.Response.Json(new ListWithCount<DbItem>(items));
}

async Task<HttpResponse> CrudList(HttpSession session)
{
    if (pgDataSource is null)
    {
        return session.Response.InternalServerError("Database not available");
    }

    var category = GetQueryString(session, "category", "electronics");
    var page = Math.Max(1, GetQueryInt(session, "page", 1));
    var limit = Math.Clamp(GetQueryInt(session, "limit", 10), 1, 50);
    var offset = (page - 1) * limit;

    await using var cmd = pgDataSource.CreateCommand(
        "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count " +
        "FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3");

    cmd.Parameters.AddWithValue(category);
    cmd.Parameters.AddWithValue(limit);
    cmd.Parameters.AddWithValue(offset);
    cmd.CommandTimeout = 2;

    await using var reader = await cmd.ExecuteReaderAsync(session.RequestAborted);

    var items = new List<DbItem>(limit);

    while (await reader.ReadAsync(session.RequestAborted))
    {
        items.Add(ReadDbItem(reader));
    }

    return session.Response.Json(new CrudListResponse
    {
        Items = items,
        Total = items.Count,
        Page = page,
        Limit = limit
    });
}

async Task<HttpResponse> CrudRead(HttpSession session)
{
    if (pgDataSource is null)
    {
        return session.Response.InternalServerError("Database not available");
    }

    var id = GetRouteInt(session, "id", 0);
    var now = Environment.TickCount64;

    if (crudCache.TryGetValue(id, out var cached) && cached.ExpiresAt > now)
    {
        return session.Response
                      .AddHeader("X-Cache", "HIT")
                      .Body(cached.Body, "application/json");
    }

    crudCache.TryRemove(id, out _);

    var item = await FetchItemById(id, session.RequestAborted);

    if (item is null)
    {
        return session.Response.NotFound();
    }

    var body = JsonSerializer.SerializeToUtf8Bytes(item, jsonOptions);
    crudCache[id] = new CrudCacheEntry(body, Environment.TickCount64 + 200);

    return session.Response
                  .AddHeader("X-Cache", "MISS")
                  .Body(body, "application/json");
}

async Task<HttpResponse> CrudCreate(HttpSession session)
{
    if (pgDataSource is null)
    {
        return session.Response.InternalServerError("Database not available");
    }

    var item = DeserializeBody<CrudItem>(session);

    if (item is null)
    {
        return session.Response.Status(400).Text("Bad Request");
    }

    await using var cmd = pgDataSource.CreateCommand(
        "INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) " +
        "VALUES ($1, $2, $3, $4, $5, true, '[\"bench\"]', 0, 0) " +
        "ON CONFLICT (id) DO UPDATE SET name = $2, price = $4, quantity = $5 " +
        "RETURNING id");

    cmd.Parameters.AddWithValue(item.Id);
    cmd.Parameters.AddWithValue(item.Name ?? "New Product");
    cmd.Parameters.AddWithValue(item.Category ?? "test");
    cmd.Parameters.AddWithValue(item.Price);
    cmd.Parameters.AddWithValue(item.Quantity);
    cmd.CommandTimeout = 2;

    item.Id = (int)(await cmd.ExecuteScalarAsync(session.RequestAborted))!;
    crudCache.TryRemove(item.Id, out _);

    return session.Response.Status(201).Json(item);
}

async Task<HttpResponse> CrudUpdate(HttpSession session)
{
    if (pgDataSource is null)
    {
        return session.Response.InternalServerError("Database not available");
    }

    var id = GetRouteInt(session, "id", 0);
    var item = DeserializeBody<CrudItem>(session);

    if (item is null)
    {
        return session.Response.Status(400).Text("Bad Request");
    }

    await using var cmd = pgDataSource.CreateCommand(
        "UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4");

    cmd.Parameters.AddWithValue(item.Name ?? "Updated");
    cmd.Parameters.AddWithValue(item.Price);
    cmd.Parameters.AddWithValue(item.Quantity);
    cmd.Parameters.AddWithValue(id);
    cmd.CommandTimeout = 2;

    var affected = await cmd.ExecuteNonQueryAsync(session.RequestAborted);

    if (affected == 0)
    {
        return session.Response.NotFound();
    }

    crudCache.TryRemove(id, out _);
    item.Id = id;

    return session.Response.Json(item);
}

async Task<DbItem?> FetchItemById(int id, CancellationToken cancellationToken)
{
    await using var cmd = pgDataSource!.CreateCommand(
        "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count " +
        "FROM items WHERE id = $1 LIMIT 1");

    cmd.Parameters.AddWithValue(id);
    cmd.CommandTimeout = 2;

    await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);

    return await reader.ReadAsync(cancellationToken) ? ReadDbItem(reader) : null;
}

DbItem ReadDbItem(NpgsqlDataReader reader)
{
    return new DbItem
    {
        Id = reader.GetInt32(0),
        Name = reader.GetString(1),
        Category = reader.GetString(2),
        Price = reader.GetInt32(3),
        Quantity = reader.GetInt32(4),
        Active = reader.GetBoolean(5),
        Tags = JsonSerializer.Deserialize<List<string>>(reader.GetString(6), jsonOptions),
        Rating = new RatingInfo { Score = reader.GetInt32(7), Count = reader.GetInt32(8) }
    };
}

T? DeserializeBody<T>(HttpSession session)
{
    try
    {
        return JsonSerializer.Deserialize<T>(session.Request.BodyString, jsonOptions);
    }
    catch (JsonException)
    {
        return default;
    }
}

static List<DatasetItem>? LoadItems()
{
    var jsonOptions = new JsonSerializerOptions(JsonSerializerDefaults.Web);
    var datasetPath = Environment.GetEnvironmentVariable("DATASET_PATH") ?? "/data/dataset.json";

    if (!File.Exists(datasetPath))
    {
        datasetPath = "../../../../../data/dataset.json";
    }

    return File.Exists(datasetPath)
        ? JsonSerializer.Deserialize<List<DatasetItem>>(File.ReadAllText(datasetPath), jsonOptions)
        : null;
}

static NpgsqlDataSource? OpenPgPool()
{
    var dbUrl = Environment.GetEnvironmentVariable("DATABASE_URL");

    if (string.IsNullOrEmpty(dbUrl))
    {
        return null;
    }

    try
    {
        var uri = new Uri(dbUrl);
        var userInfo = uri.UserInfo.Split(':');
        var maxConn = int.TryParse(Environment.GetEnvironmentVariable("DATABASE_MAX_CONN"), out var p) && p > 0
            ? p
            : 256;
        var minConn = Math.Min(64, maxConn);
        var connStr =
            $"Host={uri.Host};Port={uri.Port};Username={userInfo[0]};Password={userInfo[1]};Database={uri.AbsolutePath.TrimStart('/')};" +
            $"Maximum Pool Size={maxConn};Minimum Pool Size={minConn};Multiplexing=true;No Reset On Close=true;Max Auto Prepare=20;Auto Prepare Min Usages=1";

        return new NpgsqlDataSourceBuilder(connStr).Build();
    }
    catch
    {
        return null;
    }
}

static int GetRouteInt(HttpSession session, string name, int fallback)
{
    if (session.Request.RouteValues is null)
    {
        return fallback;
    }

    if (session.Request.RouteValues.TryGetValue(name, out var value) &&
        int.TryParse(value, out var parsed))
    {
        return parsed;
    }

    if (session.Request.RouteValues.TryGetValue($":{name}", out value) &&
        int.TryParse(value, out parsed))
    {
        return parsed;
    }

    return fallback;
}

static int GetQueryInt(HttpSession session, string name, int fallback)
{
    return session.Request.Query.TryGetValue(name, out var value) &&
           int.TryParse(value, out var parsed)
        ? parsed
        : fallback;
}

static string GetQueryString(HttpSession session, string name, string fallback)
{
    return session.Request.Query.TryGetValue(name, out var value) && !string.IsNullOrEmpty(value)
        ? value
        : fallback;
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

sealed record CrudCacheEntry(byte[] Body, long ExpiresAt);
