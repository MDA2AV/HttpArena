using System.IO.Compression;
using System.Security.Cryptography.X509Certificates;
using Microsoft.Extensions.FileProviders;
using Microsoft.AspNetCore.StaticFiles;
using Microsoft.AspNetCore.ResponseCompression;
using Microsoft.AspNetCore.Server.Kestrel.Core;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();

builder.Services.AddCodeBehind();
builder.Services.AddSingleton<DatasetService>();

// json-comp: gzip and brotli at level 1
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

    if (hasCert)
    {
        using var pem = X509Certificate2.CreateFromPemFile(certPath, keyPath);
        var cert = X509CertificateLoader.LoadPkcs12(pem.Export(X509ContentType.Pkcs12), null);
        options.ListenAnyIP(8081, lo =>
        {
            lo.Protocols = HttpProtocols.Http1;
            lo.UseHttps(cert);
        });
    }
});

var app = builder.Build();

var staticContentTypes = new FileExtensionContentTypeProvider();
staticContentTypes.Mappings[".webp"] = "image/webp";
staticContentTypes.Mappings[".woff2"] = "font/woff2";

var staticPath = Environment.GetEnvironmentVariable("STATIC_PATH") ?? "/data/static";

if (Directory.Exists(staticPath))
{
    app.UseStaticFiles(new StaticFileOptions
    {
        FileProvider = new PhysicalFileProvider(staticPath),
        RequestPath = "/static",
        ContentTypeProvider = staticContentTypes,
        ServeUnknownFileTypes = false
    });

    // /static/* that UseStaticFiles could not resolve must be 404, not fall through
    // to CodeBehind (which would answer 200 with an empty body).
    app.Use(async (context, next) =>
    {
        if (context.Request.Path.StartsWithSegments("/static")
            && !context.Response.HasStarted)
        {
            context.Response.StatusCode = 404;
            return;
        }
        await next();
    });
}

app.UseResponseCompression();
app.UseCodeBehindAsync();
app.Run();
