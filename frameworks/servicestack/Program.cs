using System.Security.Cryptography.X509Certificates;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using ServiceStack;
using ServiceStack.Benchmarks;

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

app.MapStaticAssets();

app.UseServiceStack(new AppHost(), options => {
    options.MapEndpoints();
});

await app.RunAsync();