using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.AspNetCore.StaticFiles;
using Microsoft.Extensions.Caching.Memory;

using ioxide.Kestrel;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();

// Only difference from aspnet-minimal: run on the ioxide io_uring transport.
// Default reactor count = Environment.ProcessorCount (one ring per thread).
builder.WebHost.UseIoxide();

builder.Services.AddMemoryCache();
builder.Services.AddRazorPages();

builder.WebHost.ConfigureKestrel(options =>
{
    options.Limits.Http2.MaxStreamsPerConnection = 256;
    options.Limits.Http2.InitialConnectionWindowSize = 2 * 1024 * 1024;
    options.Limits.Http2.InitialStreamWindowSize = 1024 * 1024;

    options.ListenAnyIP(8080, lo =>
    {
        lo.Protocols = HttpProtocols.Http1;
    });

    // h2c prior-knowledge listener for the baseline-h2c / json-h2c profiles.
    options.ListenAnyIP(8082, lo =>
    {
        lo.Protocols = HttpProtocols.Http2;
    });

    // NOTE: TLS listeners (8443/8081) and HTTP/3 are intentionally omitted. The ioxide
    // Kestrel transport doesn't serve HTTP-over-TLS reliably yet — the TLS handshake
    // completes, but the SslStream<->pipe path (especially HTTP/2-over-TLS) is a tracked
    // follow-up. See README. Re-add these listeners + the json-tls/h2/h3 tests once fixed.
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
