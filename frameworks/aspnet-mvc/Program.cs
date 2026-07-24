using System.Security.Cryptography.X509Certificates;

using HttpArena.Services;
using HttpArena.Types;

using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.Extensions.FileProviders;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();

builder.Services.AddControllersWithViews()
    .AddJsonOptions(o => o.JsonSerializerOptions.TypeInfoResolverChain.Insert(0, AppJsonContext.Default));

// Framework-agnostic application layer (Services/ + Types/), shared with the
// other C# entries.
builder.Services.AddSingleton<DatabaseService>();
builder.Services.AddSingleton<DatasetService>();
builder.Services.AddSingleton<ItemService>();
builder.Services.AddSingleton<FortuneService>();

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

builder.Services.AddResponseCompression();

var app = builder.Build();

app.UseResponseCompression();

app.Use((ctx, next) =>
{
    ctx.Response.Headers.Server = "aspnet-mvc";
    return next();
});

// Load the dataset and open the Postgres/Redis connections at startup
// instead of on the first request.
_ = app.Services.GetRequiredService<DatasetService>();
_ = app.Services.GetRequiredService<ItemService>();
_ = app.Services.GetRequiredService<FortuneService>();

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
