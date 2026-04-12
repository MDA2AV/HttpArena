using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.AspNetCore.StaticFiles;
using Microsoft.Extensions.FileProviders;

using System.Security.Cryptography.X509Certificates;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();

var certPath = Environment.GetEnvironmentVariable("TLS_CERT") ?? "/certs/server.crt";
var keyPath = Environment.GetEnvironmentVariable("TLS_KEY") ?? "/certs/server.key";
var hasCert = File.Exists(certPath) && File.Exists(keyPath);

builder.WebHost.ConfigureKestrel(options =>
{
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

builder.Services.AddResponseCompression()
                .AddControllers();

var app = builder.Build();

app.UseResponseCompression();

app.Use((ctx, next) =>
{
    ctx.Response.Headers["Server"] = "aspnet-minimal";
    return next();
});

AppData.Load();

app.MapControllers();

if (Directory.Exists("/data/static"))
{
    app.UseStaticFiles(new StaticFileOptions
    {
        FileProvider = new PhysicalFileProvider("/data/static"),
        RequestPath = "/static"
    });
}

app.Run();
