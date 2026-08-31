using System.Net;
using System.Security.Cryptography.X509Certificates;

using genhttp;

using GenHTTP.Engine.Kestrel;
using GenHTTP.Modules.Compression;
using Microsoft.Extensions.Logging.Abstractions;

var certPath = Environment.GetEnvironmentVariable("TLS_CERT") ?? "/certs/server.crt";
var keyPath = Environment.GetEnvironmentVariable("TLS_KEY") ?? "/certs/server.key";
var hasCert = File.Exists(certPath) && File.Exists(keyPath);

var app = Project.Create();

var host = Host.Create()
               .Handler(app)
               .Compression()
               .Logging(NullLoggerFactory.Instance, false);

host.Bind(IPAddress.Any, 8080);

if (hasCert)
{
    host.Bind(IPAddress.Any, 8081, X509Certificate2.CreateFromPemFile(certPath, keyPath));
    host.Bind(IPAddress.Any, 8443, X509Certificate2.CreateFromPemFile(certPath, keyPath), enableQuic: true);
}

await host.RunAsync();
