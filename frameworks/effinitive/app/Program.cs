using System.Text.Json;
using EffinitiveFramework.Core;
using EffinitiveFramework.Core.WebSocket;

var certPath = Environment.GetEnvironmentVariable("TLS_CERT") ?? "/certs/server.crt";
var keyPath = Environment.GetEnvironmentVariable("TLS_KEY") ?? "/certs/server.key";
var hasCert = File.Exists(certPath) && File.Exists(keyPath);

// Static files: Docker mounts at /data/static, fallback to local wwwroot/static
var staticRoot = Directory.Exists("/data/static") ? "/data/static" : Path.Combine(AppContext.BaseDirectory, "wwwroot", "static");

var builder = EffinitiveApp.Create()
    .UsePort(8080)
    .UseResponseCompression()
    .UseStaticFiles(staticRoot, "/static")
    .MapWebSocket("/ws", async (ws, ct) =>
    {
        while (ws.IsOpen)
        {
            var msg = await ws.ReceiveAsync(ct);
            if (msg == null) break;
            await ws.SendAsync(msg.Value.Data, msg.Value.Type, ct);
        }
    })
    .Configure(options =>
    {
        options.EnableDebugLogging = false;
        options.MaxConcurrentConnections = 65536;
        options.HeaderTimeout = TimeSpan.FromSeconds(30);
        options.RequestTimeout = TimeSpan.FromSeconds(60);
        options.IdleTimeout = TimeSpan.FromSeconds(120);
        options.MaxRequestBodySize = 30 * 1024 * 1024;
        options.JsonOptions = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            PropertyNameCaseInsensitive = true,
            WriteIndented = false
        };
    });

if (hasCert)
{
    builder
        .UseHttpsPort(8443)
        .ConfigureTls(opts =>
        {
            opts.CertificatePath = certPath;
            opts.KeyPath = keyPath;
        });
}

var app = builder
    .MapEndpoints()
    .Build();

var cts = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; cts.Cancel(); };

await app.RunAsync(cts.Token);
