using System.IO.Compression;
using System.Security.Cryptography.X509Certificates;

using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.AspNetCore.StaticFiles;
using Microsoft.AspNetCore.ResponseCompression;

var builder = WebApplication.CreateSlimBuilder(args);

builder.Services.ConfigureHttpJsonOptions(options =>
{
  options.SerializerOptions.TypeInfoResolverChain.Insert(0, AppJsonContext.Default);
});
builder.Logging.ClearProviders();

var certPath = Environment.GetEnvironmentVariable("TLS_CERT") ?? "/certs/server.crt";
var keyPath = Environment.GetEnvironmentVariable("TLS_KEY") ?? "/certs/server.key";
var hasCert = File.Exists(certPath) && File.Exists(keyPath);

builder.WebHost.ConfigureKestrel(options =>
{
    options.AddServerHeader = false;
    options.Limits.Http2.MaxStreamsPerConnection = 256;
    options.Limits.Http2.InitialConnectionWindowSize = 2 * 1024 * 1024;
    options.Limits.Http2.InitialStreamWindowSize = 1024 * 1024;

    options.ListenAnyIP(8080, lo =>
    {
        lo.Protocols = HttpProtocols.Http1;
    });

    if (hasCert)
    {
        options.ListenAnyIP(8443, lo =>
        {
            lo.Protocols = HttpProtocols.Http1AndHttp2AndHttp3;
            lo.UseHttps(X509Certificate2.CreateFromPemFile(certPath, keyPath));
        });
    }
});

builder.Services.AddResponseCompression(options =>
{
    options.EnableForHttps = true;
});
builder.Services.Configure<GzipCompressionProviderOptions>(options =>
{
    options.Level = CompressionLevel.Fastest;
});

var app = builder.Build();

app.UseResponseCompression();

app.Use((ctx, next) =>
{
    ctx.Response.Headers["Server"] = "aspnet-minimal-aot";
    return next();
});

AppData.Load();

app.MapGet("/pipeline", Handlers.Text);

app.MapGet("/baseline11", Handlers.Sum);
app.MapPost("/baseline11", Handlers.SumBody);
app.MapGet("/baseline2", Handlers.Sum);

app.MapPost("/upload", Handlers.Upload);
app.MapGet("/json/{count}", Handlers.Json);
app.MapGet("/db", Handlers.Database);
app.MapGet("/async-db", Handlers.AsyncDatabase);

if (Directory.Exists("/data/static"))
{
    var mimeTypes = new Dictionary<string, string>
    {
        [".css"] = "text/css", [".js"] = "application/javascript", [".html"] = "text/html",
        [".woff2"] = "font/woff2", [".svg"] = "image/svg+xml", [".webp"] = "image/webp", [".json"] = "application/json",
    };
    var staticFiles = new Dictionary<string, (byte[] data, byte[]? br, byte[]? gz, string contentType)>();
    foreach (var file in Directory.GetFiles("/data/static"))
    {
        var name = Path.GetFileName(file);
        if (name.EndsWith(".br") || name.EndsWith(".gz")) continue;
        var ext = Path.GetExtension(name);
        var ct = mimeTypes.GetValueOrDefault(ext, "application/octet-stream");
        var brPath = file + ".br";
        var gzPath = file + ".gz";
        staticFiles[name] = (
            File.ReadAllBytes(file),
            File.Exists(brPath) ? File.ReadAllBytes(brPath) : null,
            File.Exists(gzPath) ? File.ReadAllBytes(gzPath) : null,
            ct
        );
    }
    app.MapGet("/static/{filename}", (string filename, HttpContext ctx) =>
    {
        if (!staticFiles.TryGetValue(filename, out var sf))
            return Results.NotFound();
        var ae = ctx.Request.Headers.AcceptEncoding.ToString();
        if (sf.br != null && ae.Contains("br"))
        {
            ctx.Response.Headers.ContentEncoding = "br";
            return Results.Bytes(sf.br, sf.contentType);
        }
        if (sf.gz != null && ae.Contains("gzip"))
        {
            ctx.Response.Headers.ContentEncoding = "gzip";
            return Results.Bytes(sf.gz, sf.contentType);
        }
        return Results.Bytes(sf.data, sf.contentType);
    });
}

app.Run();
