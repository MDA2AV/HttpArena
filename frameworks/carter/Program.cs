using System.IO.Compression;
using System.Security.Cryptography.X509Certificates;

using Carter;

using HttpArena.Carter;

using Microsoft.AspNetCore.ResponseCompression;
using Microsoft.AspNetCore.Server.Kestrel.Core;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();

builder.Services.AddCarter();
builder.Services.AddSingleton<DatasetService>();

// json-comp: gzip and brotli at level 1, the level the profile asks for.
builder.Services.AddResponseCompression(o =>
{
    o.EnableForHttps = true;
    o.Providers.Add<GzipCompressionProvider>();
    o.Providers.Add<BrotliCompressionProvider>();
    o.MimeTypes = ["application/json"];
});
builder.Services.Configure<GzipCompressionProviderOptions>(o => o.Level = CompressionLevel.Fastest);
builder.Services.Configure<BrotliCompressionProviderOptions>(o => o.Level = CompressionLevel.Fastest);

var certPath = Environment.GetEnvironmentVariable("TLS_CERT") ?? "/certs/server.crt";
var keyPath = Environment.GetEnvironmentVariable("TLS_KEY") ?? "/certs/server.key";
var hasCert = File.Exists(certPath) && File.Exists(keyPath);

builder.WebHost.ConfigureKestrel(options =>
{
    options.Limits.MaxRequestBodySize = 64L * 1024 * 1024;

    options.ListenAnyIP(8080, lo => lo.Protocols = HttpProtocols.Http1);

    // HTTP/1.1-only TLS listener for json-tls. Kestrel advertises http/1.1 via
    // ALPN, so an h2-capable client is never offered the upgrade on this port;
    // 8443 is where h2 would live. A missing /certs leaves it down rather than
    // aborting startup, since validate.sh mounts the directory only for
    // entries subscribed to a TLS test.
    if (hasCert)
    {
        var cert = X509Certificate2.CreateFromPemFile(certPath, keyPath);
        options.ListenAnyIP(8081, lo =>
        {
            lo.Protocols = HttpProtocols.Http1;
            lo.UseHttps(cert);
        });
    }
});

var app = builder.Build();
app.UseResponseCompression();
app.MapCarter();
app.Run();
