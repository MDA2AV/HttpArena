using System.Buffers.Text;
using System.Runtime.InteropServices;

using Monoxide;

using ioxide;

namespace MonoxideArena;

/// <summary>
/// Monoxide arena entry — the HttpArena H1 profiles served through the Monoxide framework on the
/// ioxide engine. Slice 1: baseline / pipelined / json (no external deps). Routing, parsing, and
/// response framing are the framework's; this file is just the route map + the json/baseline shapes.
/// </summary>
internal static class Program
{
    private static Dataset _ds = Dataset.Empty;

    private static PosixSignalRegistration? _sigTerm;
    private static PosixSignalRegistration? _sigInt;

    private static int Main()
    {
        // Exit promptly on docker stop / Ctrl-C (closes sockets before the bench's next profile).
        _sigTerm = PosixSignalRegistration.Create(PosixSignal.SIGTERM, ctx => { ctx.Cancel = true; Environment.Exit(0); });
        _sigInt  = PosixSignalRegistration.Create(PosixSignal.SIGINT,  ctx => { ctx.Cancel = true; Environment.Exit(0); });

        int reactors = Math.Min(Environment.ProcessorCount, 64);
        if (int.TryParse(Environment.GetEnvironmentVariable("IOXIDE_REACTORS"), out int r) && r > 0)
            reactors = r;

        ushort port = 8080;
        if (ushort.TryParse(Environment.GetEnvironmentVariable("IOXIDE_PORT"), out ushort p) && p > 0)
            port = p;

        string dsPath = Environment.GetEnvironmentVariable("IOXIDE_DATASET") ?? "/data/dataset.json";
        _ds = Dataset.Load(dsPath);

        var config = new ServerConfig
        {
            Port              = port,
            ReactorCount      = reactors,
            Incremental       = false,
            RecvBufferSize    = 16 * 1024,
            BufferRingEntries = 256,
        };

        MonoxideApp app = MonoxideApp.Create(config)
            .MapGet("/pipeline", static ctx => ctx.Text("ok"u8))
            .MapGet("/json/{count}", Json)     // path param /json/<count>?m=<mult>; brotli on Accept-Encoding: br
            .MapPost("/upload", Upload);       // POST body byte count

        string staticRoot = Environment.GetEnvironmentVariable("IOXIDE_STATIC") ?? "/data/static";
        bool hasStatic = Directory.Exists(staticRoot);
        if (hasStatic)
            app.MapStatic("/static", staticRoot);   // ioxide.file-backed, precompressed-aware

        app.MapFallback(Baseline);             // /baseline11, /, and anything else → a + b + body

        Console.WriteLine($"[monoxide] {reactors} reactors on :{port} (dataset={_ds.Count} items, static={(hasStatic ? "on" : "off")})");
        app.Run();

        return 0;
    }

    // GET /json/{count}?m={mult} → {"items":[...],"count":N}, total = price*quantity*m.
    private static void Json(MonoxideContext ctx)
    {
        if (!ctx.TryRouteInt(out int count) || count < 1 || count > _ds.Count)
        {
            ctx.Status("404 Not Found"u8);
            return;
        }

        long m = 1;
        if (ctx.TryQuery("m"u8, out ReadOnlySpan<byte> mv))
            Utf8Parser.TryParse(mv, out m, out _);

        ctx.Append("{\"items\":["u8);
        for (int i = 0; i < count; i++)
        {
            if (i > 0) ctx.Append(","u8);
            ref readonly Item it = ref _ds.Items[i];
            ctx.Append("{\"id\":"u8);                 ctx.AppendInt(it.Id);
            ctx.Append(",\"name\":\""u8);             ctx.Append(it.Name);
            ctx.Append("\",\"category\":\""u8);       ctx.Append(it.Category);
            ctx.Append("\",\"price\":"u8);            ctx.AppendInt(it.Price);
            ctx.Append(",\"quantity\":"u8);           ctx.AppendInt(it.Quantity);
            ctx.Append(it.Active ? ",\"active\":true,\"tags\":["u8 : ",\"active\":false,\"tags\":["u8);
            for (int t = 0; t < it.Tags.Length; t++)
            {
                if (t > 0) ctx.Append(","u8);
                ctx.Append("\""u8); ctx.Append(it.Tags[t]); ctx.Append("\""u8);
            }
            ctx.Append("],\"rating\":{\"score\":"u8); ctx.AppendInt(it.Score);
            ctx.Append(",\"count\":"u8);              ctx.AppendInt(it.RatingCount);
            ctx.Append("},\"total\":"u8);             ctx.AppendInt(it.Price * it.Quantity * m);
            ctx.Append("}"u8);
        }
        ctx.Append("],\"count\":"u8); ctx.AppendInt(count);
        ctx.Append("}"u8);

        if (ctx.AcceptsBrotli) ctx.JsonBrotli();
        else ctx.Json();
    }

    // POST /upload → text/plain decimal of the received body byte count (the loop frames the body).
    private static void Upload(MonoxideContext ctx)
    {
        Span<byte> num = stackalloc byte[16];
        Utf8Formatter.TryFormat(ctx.Body.Length, num, out int n);
        ctx.Text(num[..n]);
    }

    // GET/POST /baseline11?a=&b= (and any unmatched path, e.g. POST /) → text/plain decimal a+b+body.
    private static void Baseline(MonoxideContext ctx)
    {
        long a = 0, b = 0;
        if (ctx.TryQuery("a"u8, out ReadOnlySpan<byte> av)) Utf8Parser.TryParse(av, out a, out _);
        if (ctx.TryQuery("b"u8, out ReadOnlySpan<byte> bv)) Utf8Parser.TryParse(bv, out b, out _);

        long sum = a + b + ParseLoose(ctx.Body.Span);
        Span<byte> num = stackalloc byte[24];
        Utf8Formatter.TryFormat(sum, num, out int n);
        ctx.Text(num[..n]);
    }

    // Parse the first run of decimal digits in the body as a long (0 if none).
    private static long ParseLoose(ReadOnlySpan<byte> body)
    {
        int i = 0;
        while (i < body.Length && (body[i] < (byte)'0' || body[i] > (byte)'9')) i++;
        long v = 0;
        while (i < body.Length && body[i] >= (byte)'0' && body[i] <= (byte)'9') { v = v * 10 + (body[i] - (byte)'0'); i++; }
        return v;
    }
}
