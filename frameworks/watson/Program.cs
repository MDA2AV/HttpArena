using System.Security.Cryptography.X509Certificates;
using System.Text;

using WatsonArena;

using WatsonWebserver;
using WatsonWebserver.Core;

using HttpMethod = WatsonWebserver.Core.HttpMethod;

// ─────────────────────────────────────────────────────────────────────────────────────────────
//  watson - Watson Webserver, the framework as a caller writes it.
//
//  Routes are declared through Watson's own routing rather than a hand-rolled dispatch: static
//  routes for the fixed paths and parameter routes for the two that carry a value, which is what
//  the library is for. HTTP/1.1 cleartext on :8080.
// ─────────────────────────────────────────────────────────────────────────────────────────────

var dataset = new Dataset();

var port = int.TryParse(Environment.GetEnvironmentVariable("PORT"), out var p) ? p : 8080;

var server = new Webserver(new WebserverSettings("*", port), NotFound);
Routes(server);

// The harness mounts a certificate pair; without it only the cleartext listener comes up.
var certPath = Environment.GetEnvironmentVariable("TLS_CERT") ?? "/certs/server.crt";
var keyPath = Environment.GetEnvironmentVariable("TLS_KEY") ?? "/certs/server.key";

Webserver? secure = null;

if (File.Exists(certPath) && File.Exists(keyPath))
{
    var settings = new WebserverSettings("*", 8081);

    settings.Ssl.Enable = true;

    // CreateFromPemFile leaves the private key ephemeral, which the TLS stack will not accept;
    // round-tripping through PKCS#12 gives it one it can keep.
    using var pem = X509Certificate2.CreateFromPemFile(certPath, keyPath);
    settings.Ssl.SslCertificate = X509CertificateLoader.LoadPkcs12(pem.Export(X509ContentType.Pkcs12), null);

    secure = new Webserver(settings, NotFound);
    Routes(secure);
}

Console.WriteLine($"[watson] :{port}{(secure is not null ? " + :8081 tls" : "")}, dataset={(dataset.IsAvailable ? dataset.Count + " items" : "absent")}");

// Start rather than StartAsync: StartAsync does not return while the listener is running, so
// awaiting it would mean the second listener never comes up.
server.Start();
secure?.Start();
await Task.Delay(Timeout.Infinite);
return;

// Both listeners answer the same routes; only the transport underneath them differs.
void Routes(Webserver target)
{
    target.Routes.PostAuthentication.Static.Add(HttpMethod.GET, "/pipeline", Pipeline);

    target.Routes.PostAuthentication.Static.Add(HttpMethod.GET, "/baseline11", Baseline);
    target.Routes.PostAuthentication.Static.Add(HttpMethod.POST, "/baseline11", Baseline);
    target.Routes.PostAuthentication.Static.Add(HttpMethod.GET, "/baseline2", Baseline);

    target.Routes.PostAuthentication.Static.Add(HttpMethod.POST, "/echo", Echo);

    target.Routes.PostAuthentication.Parameter.Add(HttpMethod.GET, "/delay/{ms}", Delay);
    target.Routes.PostAuthentication.Parameter.Add(HttpMethod.GET, "/json/{count}", Json);
}

// ── routes ──────────────────────────────────────────────────────────────────────────────────

// POST /echo - the bytes that arrived go back unchanged.
async Task Echo(HttpContextBase ctx)
{
    ctx.Response.ContentType = "application/octet-stream";
    await ctx.Response.Send(ctx.Request.DataAsBytes ?? []);
}

async Task Pipeline(HttpContextBase ctx)
{
    ctx.Response.ContentType = "text/plain";
    await ctx.Response.Send("ok");
}

// GET /baseline11?a=1&b=2 - the sum as text. POST adds the body to it.
async Task Baseline(HttpContextBase ctx)
{
    var total = Query(ctx, "a") + Query(ctx, "b");

    if (ctx.Request.Method == HttpMethod.POST)
    {
        var body = ctx.Request.DataAsString;

        if (!string.IsNullOrEmpty(body) && int.TryParse(body, out var fromBody))
        {
            total += fromBody;
        }
    }

    ctx.Response.ContentType = "text/plain";
    await ctx.Response.Send(total.ToString());
}

// GET /delay/{ms} - answer after the wait, echoing the value back.
async Task Delay(HttpContextBase ctx)
{
    if (!int.TryParse(ctx.Request.Url.Parameters["ms"], out var ms) || ms < 0)
    {
        await NotFound(ctx);
        return;
    }

    if (ms > 0)
    {
        // Registers a timer and yields rather than holding a thread, so the number of waits in
        // flight is bounded by memory instead of the thread pool.
        await Task.Delay(ms);
    }

    ctx.Response.ContentType = "text/plain";
    await ctx.Response.Send(ms.ToString());
}

// GET /json/{count}?m={multiplier}
async Task Json(HttpContextBase ctx)
{
    if (!int.TryParse(ctx.Request.Url.Parameters["count"], out var count))
    {
        await NotFound(ctx);
        return;
    }

    var multiplier = ctx.Request.QuerystringExists("m") && int.TryParse(ctx.Request.RetrieveQueryValue("m"), out var m)
        ? m
        : 1;

    var accepted = ctx.Request.Headers["Accept-Encoding"] ?? string.Empty;

    var body = dataset.Render(count, multiplier,
                              accepted.Contains("br", StringComparison.OrdinalIgnoreCase),
                              accepted.Contains("gzip", StringComparison.OrdinalIgnoreCase),
                              out var encoding);

    if (body is null)
    {
        ctx.Response.StatusCode = 503;
        await ctx.Response.Send();
        return;
    }

    ctx.Response.ContentType = "application/json";
    ctx.Response.Headers.Add("Vary", "Accept-Encoding");

    if (encoding is not null)
    {
        ctx.Response.Headers.Add("Content-Encoding", encoding);
    }

    await ctx.Response.Send(body);
}

async Task NotFound(HttpContextBase ctx)
{
    ctx.Response.StatusCode = 404;
    ctx.Response.ContentType = "text/plain";
    await ctx.Response.Send();
}

static int Query(HttpContextBase ctx, string name)
    => ctx.Request.QuerystringExists(name) && int.TryParse(ctx.Request.RetrieveQueryValue(name), out var value)
        ? value
        : 0;
