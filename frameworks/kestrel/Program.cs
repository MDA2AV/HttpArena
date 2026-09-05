using System.Buffers;
using System.Buffers.Text;
using System.Security.Cryptography.X509Certificates;
using System.Text;

using KestrelArena;

using Microsoft.AspNetCore.Server.Kestrel.Core;

// ─────────────────────────────────────────────────────────────────────────────────────────────
//  kestrel - Kestrel itself, with nothing above it.
//
//  There is no routing middleware, no MVC, no minimal-API endpoint mapping and no model binding:
//  one RequestDelegate reads the path and answers. That is the point of the entry. aspnet-minimal
//  measures ASP.NET Core as people write it; this measures the server underneath, so the distance
//  between the two rows is what the framework layer costs rather than what Kestrel costs.
//
//    :8080  HTTP/1.1 cleartext              baseline, pipelined, limited-conn, async, latency, json-comp, 8gbit
//    :8082  HTTP/2 cleartext (prior knowledge)  baseline-h2c, json-h2c
//    :8081  HTTP/1.1 over TLS               json-tls, static-tls
//    :8443  HTTP/1.1 + HTTP/2 over TCP,     baseline-h2, static-h2
//           HTTP/3 over QUIC, same port     baseline-h3, static-h3
// ─────────────────────────────────────────────────────────────────────────────────────────────

var dataset = new Dataset();

var certPath = Environment.GetEnvironmentVariable("TLS_CERT") ?? "/certs/server.crt";
var keyPath = Environment.GetEnvironmentVariable("TLS_KEY") ?? "/certs/server.key";
var hasCert = File.Exists(certPath) && File.Exists(keyPath);

// CreateBuilder rather than CreateSlimBuilder: the slim host trims the QUIC transport, so the TCP
// listeners come up, HTTP/3 silently does not, and nothing is logged about it. Neither host brings
// any routing or MVC with it, which is what "pure" means here.
var builder = WebApplication.CreateBuilder(args);

// Warnings and errors still reach stderr: a QUIC listener that fails to bind is otherwise silent,
// and the h3 profiles would just look like the server ignoring them.
builder.Logging.SetMinimumLevel(LogLevel.Warning);

builder.WebHost.ConfigureKestrel(options =>
{
    options.AddServerHeader = false;

    // The h2 profiles open few connections and many streams, so the defaults would make the
    // windows the limit rather than the server.
    options.Limits.Http2.MaxStreamsPerConnection = 256;
    options.Limits.Http2.InitialConnectionWindowSize = 2 * 1024 * 1024;
    options.Limits.Http2.InitialStreamWindowSize = 1024 * 1024;

    options.ListenAnyIP(8080, o => o.Protocols = HttpProtocols.Http1);

    // Protocols = Http2 with no UseHttps gives cleartext HTTP/2 with prior knowledge, which is
    // what the h2c profiles speak.
    options.ListenAnyIP(8082, o => o.Protocols = HttpProtocols.Http2);

    if (hasCert)
    {
        // CreateFromPemFile hands back a certificate whose private key is ephemeral, which msquic
        // cannot use - the TCP listeners come up and the QUIC one silently does not. Round-tripping
        // through PKCS#12 gives it a key it will accept.
        using var pem = X509Certificate2.CreateFromPemFile(certPath, keyPath);
        var certificate = X509CertificateLoader.LoadPkcs12(pem.Export(X509ContentType.Pkcs12), null);

        options.ListenAnyIP(8081, o =>
        {
            o.Protocols = HttpProtocols.Http1;
            o.UseHttps(certificate);
        });

        options.ListenAnyIP(8443, o =>
        {
            o.Protocols = HttpProtocols.Http1AndHttp2AndHttp3;
            o.UseHttps(certificate);
        });
    }
});

var app = builder.Build();

app.Run(async ctx =>
{
    var request = ctx.Request;
    var path = request.Path.Value;

    if (path is null || path.Length < 2)
    {
        ctx.Response.StatusCode = 404;
        return;
    }

    // Dispatch on the first segment. Ordered by how often the profiles ask for each.
    switch (Segment(path, 1, out var rest))
    {
        case "baseline11":
        case "baseline2":
            await Baseline(ctx);
            return;

        case "json":
            await Json(ctx, rest);
            return;

        case "pipeline":
            await Text(ctx, "ok");
            return;

        case "delay":
            await Delay(ctx, rest);
            return;

        case "static":
            if (StaticFiles.Available && await StaticFiles.TryServeAsync(ctx, rest))
            {
                return;
            }
            break;

        case "echo":
            await Echo(ctx);
            return;
    }

    ctx.Response.StatusCode = 404;
});

app.Run();
return;

// ── handlers ────────────────────────────────────────────────────────────────────────────────

// GET /baseline11?a=1&b=2 - the sum as text. POST adds the body to it.
async Task Baseline(HttpContext ctx)
{
    var query = ctx.Request.Query;

    _ = int.TryParse(query["a"], out var a);
    _ = int.TryParse(query["b"], out var b);

    var total = a + b;

    if (HttpMethods.IsPost(ctx.Request.Method))
    {
        using var reader = new StreamReader(ctx.Request.Body);
        var body = await reader.ReadToEndAsync();

        if (int.TryParse(body, out var extra))
        {
            total += extra;
        }
    }

    await Text(ctx, total.ToString());
}

// GET /json/{count}?m={multiplier}
async Task Json(HttpContext ctx, string rest)
{
    if (!int.TryParse(rest, out var count))
    {
        ctx.Response.StatusCode = 404;
        return;
    }

    var multiplier = 1;

    if (ctx.Request.Query["m"] is { Count: > 0 } m && int.TryParse(m[0], out var parsed))
    {
        multiplier = parsed;
    }

    var accepted = ctx.Request.Headers.AcceptEncoding;

    // Rendered into per-thread scratch and written before anything can await, so the span stays
    // valid for the write.
    var body = dataset.Render(count, multiplier,
                              Accepts(accepted, "br"), Accepts(accepted, "gzip"),
                              out var encoding);

    if (!dataset.IsAvailable)
    {
        ctx.Response.StatusCode = 503;
        return;
    }

    var response = ctx.Response;
    response.ContentType = "application/json";
    response.Headers.Vary = "Accept-Encoding";

    if (encoding is not null)
    {
        response.Headers.ContentEncoding = encoding;
    }

    response.ContentLength = body.Length;

    // BodyWriter takes the span as it stands; Body.WriteAsync would need a Memory, and building
    // one means copying the scratch into a fresh array on every request.
    response.BodyWriter.Write(body);
    await response.BodyWriter.FlushAsync();
}

// GET /delay/{ms} - answer after the wait, echoing the value back.
async Task Delay(HttpContext ctx, string rest)
{
    if (!int.TryParse(rest, out var ms) || ms < 0)
    {
        ctx.Response.StatusCode = 404;
        return;
    }

    if (ms > 0)
    {
        await Task.Delay(ms);
    }

    await Text(ctx, ms.ToString());
}

// POST /echo - the bytes that arrived go back unchanged.
//
// With a declared length the body is read once into a pooled buffer of exactly that size and
// written once: a MemoryStream would double as it grew and land its final buffer on the large
// object heap, which is collected as gen2. A chunked request carries no length to size against,
// so it keeps the copy-then-write path.
async Task Echo(HttpContext ctx)
{
    var response = ctx.Response;
    response.ContentType = "application/octet-stream";

    if (ctx.Request.ContentLength is > 0 and var length)
    {
        var size = (int)length;
        var buffer = ArrayPool<byte>.Shared.Rent(size);

        try
        {
            await ctx.Request.Body.ReadExactlyAsync(buffer.AsMemory(0, size));

            response.ContentLength = size;
            await response.Body.WriteAsync(buffer.AsMemory(0, size));
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
        }

        return;
    }

    using var buffered = new MemoryStream();
    await ctx.Request.Body.CopyToAsync(buffered);

    response.ContentLength = buffered.Length;
    await response.Body.WriteAsync(buffered.GetBuffer().AsMemory(0, (int)buffered.Length));
}

static bool Accepts(Microsoft.Extensions.Primitives.StringValues accepted, string token)
{
    foreach (var value in accepted)
    {
        if (value is not null && value.Contains(token, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }
    }

    return false;
}

static async Task Text(HttpContext ctx, string value)
{
    var response = ctx.Response;
    response.ContentType = "text/plain";
    response.ContentLength = Encoding.UTF8.GetByteCount(value);

    // Encoded straight into the writer's buffer rather than into an array first.
    var writer = response.BodyWriter;
    var span = writer.GetSpan((int)response.ContentLength.Value);

    writer.Advance(Encoding.UTF8.GetBytes(value, span));

    await writer.FlushAsync();
}

// The path segment starting at `start`, with everything after it (minus a leading slash) in `rest`.
static string Segment(string path, int start, out string rest)
{
    var end = path.IndexOf('/', start);

    if (end < 0)
    {
        rest = "";
        return path[start..];
    }

    rest = path[(end + 1)..];
    return path[start..end];
}
