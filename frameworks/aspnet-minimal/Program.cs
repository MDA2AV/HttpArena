using System.Security.Cryptography.X509Certificates;

using HttpArena;
using HttpArena.Services;
using HttpArena.Types;

using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.AspNetCore.StaticFiles;
using Microsoft.Extensions.FileProviders;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();
builder.Services.AddRazorPages();

builder.Services.ConfigureHttpJsonOptions(o =>
    o.SerializerOptions.TypeInfoResolverChain.Insert(0, AppJsonContext.Default));

builder.Services.AddSingleton<DatabaseService>();
builder.Services.AddSingleton<DatasetService>();
builder.Services.AddSingleton<ItemService>();
builder.Services.AddSingleton<FortuneService>();

var certPath = Environment.GetEnvironmentVariable("TLS_CERT") ?? "/certs/server.crt";
var keyPath = Environment.GetEnvironmentVariable("TLS_KEY") ?? "/certs/server.key";
var hasCert = File.Exists(certPath) && File.Exists(keyPath);

// The opt-in tls_check gets its own listener on :9000 and its own pair at
// /certs-tls. It rotates certificates under a running server, and pointing it
// at /certs would move the ground under json-tls, static-tls and the h2
// profiles in the same validation run.
var tlsCheckCert = "/certs-tls/server.crt";
var tlsCheckKey = "/certs-tls/server.key";
var hasTlsCheck = File.Exists(tlsCheckCert) && File.Exists(tlsCheckKey);

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
        // Re-read when the files change, so a rotation lands without a restart.
        // The selector below runs per handshake, which is what makes that
        // visible to the next connection rather than the next process.
        var cert = new RotatingCertificate(certPath, keyPath);

        options.ListenAnyIP(8443, lo =>
        {
            lo.Protocols = HttpProtocols.Http1AndHttp2AndHttp3;
            lo.UseHttps(https => https.ServerCertificateSelector = (_, _) => cert.Current);
        });

        // HTTP/1.1-only TLS listener for the json-tls profile. Kestrel
        // advertises http/1.1 via ALPN so HTTP/1.1-only clients (wrk) negotiate
        // correctly and never upgrade to h2.
        options.ListenAnyIP(8081, lo =>
        {
            lo.Protocols = HttpProtocols.Http1;
            lo.UseHttps(https => https.ServerCertificateSelector = (_, _) => cert.Current);
        });
    }

    if (hasTlsCheck)
    {
        // Same rotating handle, a different pair. The selector runs per
        // handshake, which is what lets a replaced file reach the next
        // connection instead of the next process.
        var checkCert = new RotatingCertificate(tlsCheckCert, tlsCheckKey);

        options.ListenAnyIP(9000, lo =>
        {
            lo.Protocols = HttpProtocols.Http1;
            lo.UseHttps(https => https.ServerCertificateSelector = (_, _) => checkCert.Current);
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

// Load the dataset and open the Postgres/Redis connections at startup
// instead of on the first request.
_ = app.Services.GetRequiredService<DatasetService>();
_ = app.Services.GetRequiredService<ItemService>();
_ = app.Services.GetRequiredService<FortuneService>();

app.MapGet("/pipeline", Handlers.Text);

app.MapGet("/baseline11", Handlers.Sum);
app.MapPost("/baseline11", Handlers.SumBody);
app.MapGet("/baseline2", Handlers.Sum);

app.MapPost("/upload", Handlers.Upload);
app.MapGet("/delay/{ms:int}", Handlers.Delay);
app.MapGet("/json/{count}", Handlers.Json);
app.MapGet("/async-db", Handlers.AsyncDatabase);

// ── CRUD endpoints ─────────────────────────────────────────────────────────
// Realistic REST API: paginated list, cached single-item read, create, update.
// Cache-aside single-item reads (Redis or in-process), invalidated on PUT.

app.MapGet("/crud/items", Handlers.CrudList);
app.MapGet("/crud/items/{id:int}", Handlers.CrudRead);
app.MapPost("/crud/items", Handlers.CrudCreate);
app.MapPut("/crud/items/{id:int}", Handlers.CrudUpdate);

// /fortunes is served by the Razor page at Pages/Fortunes.cshtml
// (route "/fortunes" declared via the page's @page directive). MapRazorPages
// wires up the MVC/Razor pipeline so the page model can render Razor markup
// — the standard ASP.NET production path for HTML responses.
app.MapRazorPages();

// Served straight out of the directory the profile mounts, rather than a copy
// taken at image build. MapStaticAssets, which this used before, resolves assets
// through a manifest generated at compile time from wwwroot: the container ended
// up holding two copies of the corpus and answering from the one the harness
// cannot touch, so a file replaced on disk was never reflected in a response.
//
// UseStaticFiles reads the file per request through the file provider, so what is
// served follows the mounted directory. Compression is still ASP.NET's own
// response compression middleware, configured above.
var staticContentTypes = new FileExtensionContentTypeProvider();
staticContentTypes.Mappings[".webp"] = "image/webp";
staticContentTypes.Mappings[".woff2"] = "font/woff2";

app.UseStaticFiles(new StaticFileOptions
{
    FileProvider = new PhysicalFileProvider("/data/static"),
    RequestPath = "/static",
    ContentTypeProvider = staticContentTypes,
    ServeUnknownFileTypes = false
});

app.Run();
