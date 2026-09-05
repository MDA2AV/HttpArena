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

var settings = new WebserverSettings("*", port);

var server = new Webserver(settings, NotFound);

server.Routes.PostAuthentication.Static.Add(HttpMethod.GET, "/pipeline", Pipeline);

server.Routes.PostAuthentication.Static.Add(HttpMethod.GET, "/baseline11", Baseline);
server.Routes.PostAuthentication.Static.Add(HttpMethod.POST, "/baseline11", Baseline);
server.Routes.PostAuthentication.Static.Add(HttpMethod.GET, "/baseline2", Baseline);

server.Routes.PostAuthentication.Parameter.Add(HttpMethod.GET, "/delay/{ms}", Delay);
server.Routes.PostAuthentication.Parameter.Add(HttpMethod.GET, "/json/{count}", Json);

Console.WriteLine($"[watson] :{port}, dataset={(dataset.IsAvailable ? dataset.Count + " items" : "absent")}");

await server.StartAsync();
await Task.Delay(Timeout.Infinite);
return;

// ── routes ──────────────────────────────────────────────────────────────────────────────────

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
