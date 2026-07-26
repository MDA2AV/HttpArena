namespace ServiceStack.Benchmarks;

using System.Text.Json;
using Npgsql;
using ServiceStack;

public class BenchmarkServices : Service
{
    private static readonly JsonSerializerOptions JsonOpts = new(JsonSerializerDefaults.Web);

    private static readonly List<DatasetItem>? Items = LoadItems();

    static List<DatasetItem>? LoadItems()
    {
        var path = Resolve("/data/dataset.json", "../../../../../../data/dataset.json");
        if (path == null) return null;

        return JsonSerializer.Deserialize<List<DatasetItem>>(File.ReadAllText(path), JsonOpts);
    }

    static string? Resolve(string primary, string fallback)
        => File.Exists(primary) ? primary : File.Exists(fallback) ? fallback : null;

    // ── /baseline11 ───────────────────────────────────────────────────────────────
    public HttpResult Get(Baseline11Get req) => ToResult(req.A + req.B);

    public async Task<HttpResult> Post(Baseline11Post req)
    {
        return ToResult(req.A + req.B + int.Parse(await Request!.GetRawBodyAsync()));
    }

    public HttpResult Get(Baseline2Get req) => ToResult(req.A + req.B);

    // ── /pipeline ─────────────────────────────────────────────────────────────
    public object Get(PipelineGet _)
    {
        Response!.ContentType = "text/plain";
        return "ok";
    }

    // ── /upload ───────────────────────────────────────────────────────────────
    public async Task<HttpResult> Post(UploadPost _)
    {
        using var ms = new MemoryStream();
        await Request!.InputStream.CopyToAsync(ms);
        return ToResult(ms.Length.ToString());
    }

    // ── /json ─────────────────────────────────────────────────────────────────
    public object Get(JsonGet req)
    {
        if (Items == null) return new ListWithCount<ProcessedItem>(new());

        int m = 1;
        if (Request?.QueryString["m"] is string mStr && int.TryParse(mStr, out var pm)) m = pm;

        var count = req.Count;
        
        if (count > Items.Count) count = Items.Count;
        if (count < 0) count = 0;

        var processed = new List<ProcessedItem>(count);
        
        for (var i = 0; i < count; i++)
            processed.Add(Items[i].ToProcessed(m));

        return new ListWithCount<ProcessedItem>(processed);
    }

    // ── /async-db (PostgreSQL) ────────────────────────────────────────────────
    public async Task<ListWithCount<object>> Get(AsyncDbGet req)
    {
        var ds = TryResolve<NpgsqlDataSource>();
        if (ds == null) return new ListWithCount<object>(new());

        var limit = Math.Clamp(req.Limit, 1, 50);

        await using var cmd = ds.CreateCommand(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count " +
            "FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3");
        cmd.Parameters.AddWithValue(req.Min);
        cmd.Parameters.AddWithValue(req.Max);
        cmd.Parameters.AddWithValue(limit);

        await using var reader = await cmd.ExecuteReaderAsync();
        var items = new List<object>();

        while (await reader.ReadAsync())
        {
            items.Add(new
            {
                id       = reader.GetInt32(0),
                name     = reader.GetString(1),
                category = reader.GetString(2),
                price    = reader.GetInt32(3),
                quantity = reader.GetInt32(4),
                active   = reader.GetBoolean(5),
                tags     = JsonSerializer.Deserialize<List<string>>(reader.GetString(6)),
                rating   = new { score = reader.GetInt32(7), count = reader.GetInt32(8) }
            });
        }

        return new ListWithCount<object>(items);
    }

    private HttpResult ToResult<T>(T data)
    {
        return new HttpResult(data.ToString(), MimeTypes.PlainText);
    }
    
}