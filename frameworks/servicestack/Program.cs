using System.Security.Cryptography.X509Certificates;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using ServiceStack;
using ServiceStack.Benchmarks;
using Microsoft.AspNetCore.StaticFiles;
using Microsoft.Extensions.FileProviders;

var certPath = Environment.GetEnvironmentVariable("TLS_CERT") ?? "/certs/server.crt";
var keyPath = Environment.GetEnvironmentVariable("TLS_KEY") ?? "/certs/server.key";
var hasCert = File.Exists(certPath) && File.Exists(keyPath);

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddResponseCompression();
builder.Logging.ClearProviders();

builder.WebHost.ConfigureKestrel(options =>
{
    options.ListenAnyIP(8080, lo =>
    {
        lo.Protocols = HttpProtocols.Http1;
    });

    if (hasCert)
    {
        options.ListenAnyIP(8081, lo =>
        {
            lo.Protocols = HttpProtocols.Http1;
            lo.UseHttps(X509Certificate2.CreateFromPemFile(certPath, keyPath));
        });
    }
});

var app = builder.Build();

app.UseResponseCompression();

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

app.UseServiceStack(new AppHost(), options => {
    options.MapEndpoints();
});

await app.RunAsync();