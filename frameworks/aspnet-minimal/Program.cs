using System.Security.Cryptography.X509Certificates;

using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.AspNetCore.StaticFiles;
using Microsoft.Extensions.Caching.Memory;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();
builder.Services.AddMemoryCache();

var certPath = Environment.GetEnvironmentVariable("TLS_CERT") ?? "/certs/server.crt";
var keyPath = Environment.GetEnvironmentVariable("TLS_KEY") ?? "/certs/server.key";
var hasCert = File.Exists(certPath) && File.Exists(keyPath);

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
    // Protocols = Http2 with no UseHttps() gives Kestrel cleartext HTTP/2
    // from the first byte. Clients that try HTTP/1.1 on this port get
    // rejected, which is what validate.sh's h2c anti-cheat requires.
    options.ListenAnyIP(8082, lo =>
    {
        lo.Protocols = HttpProtocols.Http2;
    });

    if (hasCert)
    {
        options.ListenAnyIP(8443, lo =>
        {
            lo.Protocols = HttpProtocols.Http1AndHttp2AndHttp3;
            lo.UseHttps(X509Certificate2.CreateFromPemFile(certPath, keyPath));
        });

        // HTTP/1.1-only TLS listener for the json-tls profile. Kestrel
        // advertises http/1.1 via ALPN so HTTP/1.1-only clients (wrk) negotiate
        // correctly and never upgrade to h2.
        options.ListenAnyIP(8081, lo =>
        {
            lo.Protocols = HttpProtocols.Http1;
            lo.UseHttps(X509Certificate2.CreateFromPemFile(certPath, keyPath));
        });
    }
});

builder.Services.AddResponseCompression();

var app = builder.Build();

app.UseResponseCompression();

app.Use((ctx, next) =>
{
    ctx.Response.Headers.Server = "aspnet-minimal";
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

app.MapStaticAssets();

app.Run();
