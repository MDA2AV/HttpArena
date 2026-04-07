using System.Security.Cryptography.X509Certificates;

using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.AspNetCore.StaticFiles;
using Microsoft.Extensions.FileProviders;

AppContext.SetSwitch("System.Net.Sockets.UseIoUringSqPoll", true);

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();

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

app.UseWhen(ctx => ctx.Request.Path.StartsWithSegments("/compression"), subApp => 
{
    subApp.UseResponseCompression();
});

app.Use((ctx, next) =>
{
    ctx.Response.Headers.Server = "aspnet-minimal";
    return next();
});

AppData.Load();

// Detect io_uring socket engine
var ioUringEnv = Environment.GetEnvironmentVariable("DOTNET_SYSTEM_NET_SOCKETS_IO_URING");
Console.WriteLine($"[io_uring] DOTNET_SYSTEM_NET_SOCKETS_IO_URING={ioUringEnv ?? "(not set)"}");
var socketAsm = typeof(System.Net.Sockets.Socket).Assembly;
var ioUringType = socketAsm.GetTypes()
    .FirstOrDefault(t => t.Name.Contains("IOUring", StringComparison.OrdinalIgnoreCase));
Console.WriteLine(ioUringType != null
    ? $"[io_uring] Runtime type found: {ioUringType.FullName} — io_uring is ACTIVE"
    : "[io_uring] No io_uring types in runtime — falling back to epoll");

app.MapGet("/pipeline", Handlers.Text);

app.MapGet("/baseline11", Handlers.Sum);
app.MapPost("/baseline11", Handlers.SumBody);
app.MapGet("/baseline2", Handlers.Sum);

app.MapPost("/upload", Handlers.Upload);
app.MapGet("/json", Handlers.Json);
app.MapGet("/compression", Handlers.Compression);
app.MapGet("/db", Handlers.Database);
app.MapGet("/async-db", Handlers.AsyncDatabase);

if (Directory.Exists("/data/static"))
{
    var typeProvider = new FileExtensionContentTypeProvider();
    
    typeProvider.Mappings[".js"] = "application/javascript";
    
    app.UseStaticFiles(new StaticFileOptions
    {
        FileProvider = new PhysicalFileProvider("/data/static"),
        ContentTypeProvider = typeProvider,
        RequestPath = "/static"
    });
}

app.Run();
