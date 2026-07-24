using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.AspNetCore.StaticFiles;
using Microsoft.Extensions.Caching.Memory;

using ioxide.Kestrel;
using ioxide.pg;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();

// Only difference from aspnet-minimal: run on the ioxide io_uring transport.
// Default reactor count = Environment.ProcessorCount (one ring per thread).
var certPath = Environment.GetEnvironmentVariable("TLS_CERT") ?? "/certs/server.crt";
var keyPath = Environment.GetEnvironmentVariable("TLS_KEY") ?? "/certs/server.key";
var hasCert = File.Exists(certPath) && File.Exists(keyPath);

builder.WebHost.UseIoxide(o =>
{
    // 64 KB per-connection write slab so larger responses (fortunes, json) fit without growing it.
    o.ConfigureServer = cfg => cfg with { WriteSlabSize = 64 * 1024 };

    // kTLS termination in the transport for the json-tls profile (HTTP/1.1 over TLS on 8081). No
    // UseHttps() below — the transport runs the TLS 1.3 handshake and the kernel does the record crypto.
    if (hasCert)
    {
        o.UseTls(certPath, keyPath, new[] { 8081 });
    }

    // Open a per-reactor ioxide.pg pool so DB queries run on the connection's reactor (thread-per-core).
    // AppData.Load() below sets PgOptions before the host starts; OnReactorStart fires when reactors start.
    o.OnReactorStart = r =>
    {
        if (AppData.PgOptions is not null)
        {
            PgPool.Start(r, AppData.PgOptions);
        }
    };
});

builder.Services.AddMemoryCache();
builder.Services.AddRazorPages();

builder.WebHost.ConfigureKestrel(options =>
{
    options.ListenAnyIP(8080, lo =>
    {
        lo.Protocols = HttpProtocols.Http1;
    });

    // HTTP/1.1-over-TLS (json-tls), terminated by the ioxide transport via kTLS — wired above by
    // UseTls(...8081). No UseHttps() here: Kestrel sees a plaintext, already-TLS connection.
    if (hasCert)
    {
        options.ListenAnyIP(8081, lo =>
        {
            lo.Protocols = HttpProtocols.Http1;
        });
    }

    // HTTP/1.1 only: cleartext h2c (8082), HTTP/2-over-TLS (8443), and HTTP/3 are intentionally omitted.
});

builder.Services.AddResponseCompression();

var app = builder.Build();

app.UseResponseCompression();

app.Use((ctx, next) =>
{
    ctx.Response.Headers.Server = "aspnet-minimal-ioxide";
    return next();
});

AppData.Load();

app.MapGet("/pipeline", Handlers.Text);

app.MapGet("/baseline11", Handlers.Sum);
app.MapPost("/baseline11", Handlers.SumBody);
app.MapGet("/baseline2", Handlers.Sum);

app.MapPost("/upload", Handlers.Upload);
app.MapGet("/json/{count}", Handlers.Json);
app.MapGet("/async-db", Handlers.AsyncDatabase);

// ── CRUD endpoints ─────────────────────────────────────────────────────────
// Realistic REST API: paginated list, cached single-item read, create, update.
// In-process IMemoryCache with 1s TTL on single-item reads, invalidated on PUT.

app.MapGet("/crud/items", Handlers.CrudList);
app.MapGet("/crud/items/{id:int}", Handlers.CrudRead);
app.MapPost("/crud/items", Handlers.CrudCreate);
app.MapPut("/crud/items/{id:int}", Handlers.CrudUpdate);

// /fortunes is served by the Razor page at Pages/Fortunes.cshtml
// (route "/fortunes" declared via the page's @page directive). MapRazorPages
// wires up the MVC/Razor pipeline so the page model can render Razor markup
// — the standard ASP.NET production path for HTML responses.
app.MapRazorPages();

app.MapStaticAssets();

app.Run();
