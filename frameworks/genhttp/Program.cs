using System.Net;
using System.Security.Cryptography.X509Certificates;

using genhttp;

using GenHTTP.Engine.Internal;
using GenHTTP.Modules.Compression;

var certPath = Environment.GetEnvironmentVariable("TLS_CERT") ?? "/certs/server.crt";
var keyPath = Environment.GetEnvironmentVariable("TLS_KEY") ?? "/certs/server.key";
var hasCert = File.Exists(certPath) && File.Exists(keyPath);

var app = Project.Create();

var host = Host.Create()
               .Handler(app)
               .Compression();

host.Bind(IPAddress.Any, 8080);

if (hasCert)
{
    host.Bind(IPAddress.Any, 8081, X509Certificate2.CreateFromPemFile(certPath, keyPath));
    host.Bind(IPAddress.Any, 8443, X509Certificate2.CreateFromPemFile(certPath, keyPath));
}

await host.RunAsync();
