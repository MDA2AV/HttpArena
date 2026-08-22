using System.Security.Cryptography.X509Certificates;
using System.Text.Json;

using FastEndpoints;

using HttpArena.Services;
using HttpArena.Types;

using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.AspNetCore.StaticFiles;
using Microsoft.Extensions.FileProviders;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();

builder.Services.AddFastEndpoints();

builder.Services.AddSingleton<DatabaseService>();
builder.Services.AddSingleton<DatasetService>();
builder.Services.AddSingleton<ItemService>();

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
        var cert = X509Certificate2.CreateFromPemFile(certPath, keyPath);

        options.ListenAnyIP(8443, lo =>
        {
            lo.Protocols = HttpProtocols.Http1AndHttp2AndHttp3;
            lo.UseHttps(cert);
        });

        // HTTP/1.1-only TLS listener for the json-tls profile. Kestrel
        // advertises http/1.1 via ALPN so HTTP/1.1-only clients (wrk) negotiate
        // correctly and never upgrade to h2.
        options.ListenAnyIP(8081, lo =>
        {
            lo.Protocols = HttpProtocols.Http1;
            lo.UseHttps(cert);
        });
    }
});

builder.Services.AddResponseCompression();

var app = builder.Build();

app.UseResponseCompression();

app.Use((ctx, next) =>
{
    ctx.Response.Headers.Server = "fastendpoints";
    return next();
});

app.UseFastEndpoints(c =>
{
    c.Serializer.Options.PropertyNamingPolicy = JsonNamingPolicy.CamelCase;
    c.Serializer.Options.PropertyNameCaseInsensitive = true;
    c.Serializer.Options.NumberHandling = System.Text.Json.Serialization.JsonNumberHandling.AllowReadingFromString;
    c.Serializer.Options.TypeInfoResolverChain.Insert(0, AppJsonContext.Default);
});

// Load the dataset and open the Postgres/Redis connections at startup
// instead of on the first request.
_ = app.Services.GetRequiredService<DatasetService>();
_ = app.Services.GetRequiredService<ItemService>();

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
