using System.Net;
using System.Security.Cryptography.X509Certificates;

using genhttp;

using GenHTTP.Api.Infrastructure;
using GenHTTP.Engine.Internal;
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

var certificateProvider = CertificateProvider.From(X509Certificate2.CreateFromPemFile(certPath, keyPath));

if (hasCert)
{
    host.Bind(IPAddress.Any, 8081, certificateProvider);
    host.Bind(IPAddress.Any, 8443, certificateProvider);
}

await host.RunAsync();
