using System.Net;

using genhttp;
using genhttp.Infrastructure;

using GenHTTP.Api.Infrastructure;

using GenHTTP.Engine.Ioxide;
using GenHTTP.Modules.Compression;

using ioxide;
using Microsoft.Extensions.Logging.Abstractions;

// Reactor count follows the available CPUs (api-4 / api-16 control this via cpuset pinning);
// override with IOXIDE_REACTORS.
var reactors = int.TryParse(Environment.GetEnvironmentVariable("IOXIDE_REACTORS"), out var rc) ? rc : Environment.ProcessorCount;

// Postgres (async-db / crud) is per-reactor: its pool is opened on each reactor's own thread.
Postgres.Configure(reactors);

Action<Reactor>? onReactorStart = Postgres.Enabled ? Postgres.Start : null;

// The engine buffers a whole response in one write slab; static assets can exceed the 16 KB default.
// Size the slab above the largest asset (plus GenHTTP's 64 KB file-copy buffer) - only when static is
// mounted, so the high-connection profiles keep the small per-connection buffer.
int? writeSlab = null;
var staticRoot = Environment.GetEnvironmentVariable("IOXIDE_STATIC") ?? "/data/static";
if (Directory.Exists(staticRoot))
{
    long largest = 0;
    foreach (var file in Directory.EnumerateFiles(staticRoot, "*", SearchOption.AllDirectories))
    {
        largest = Math.Max(largest, new FileInfo(file).Length);
    }
    writeSlab = (int)largest + 128 * 1024;
}

// The harness mounts a certificate pair; without it only the plaintext listeners come up.
var certPath = Environment.GetEnvironmentVariable("TLS_CERT") ?? "/certs/server.crt";
var keyPath = Environment.GetEnvironmentVariable("TLS_KEY") ?? "/certs/server.key";
var hasCert = File.Exists(certPath) && File.Exists(keyPath);

var options = new EngineOptions
{
    Reactor = new ReactorOptions
    {
        ReactorCount = reactors,
        RecvSlots = 256,
    },
    Tcp = new TcpTransportOptions
    {
        WriteSlabSize = writeSlab ?? new TcpTransportOptions().WriteSlabSize,
    },
};

var host = Host.Create(onReactorStart: onReactorStart, options: options)
               .Logging(NullLoggerFactory.Instance, false)
               .Handler(Project.Create())
               .Compression(CompressedContent.Default());

//   :8080  HTTP/1.1 plaintext          baseline, pipelined, limited-conn, async, json-comp, async-db, ws
//   :8082  HTTP/1.1 + HTTP/2 cleartext baseline-h2c, json-h2c - the preface decides which
host.Bind(IPAddress.Any, 8080, HttpProtocols.Http1);
host.Bind(IPAddress.Any, 8082, HttpProtocols.Http1AndHttp2);

if (hasCert)
{
    // The engine terminates TLS itself now, in OpenSSL, so the certificate is named as files -
    // which is also the only form HTTP/3 takes, ngtcp2 loading PEM by path.
    var certificate = new FileCertificateProvider(certPath, keyPath);

    //   :8081  HTTP/1.1 over TLS                 json-tls, static-tls, 8gbit
    //   :8443  HTTP/1.1 + HTTP/2 over TCP,       baseline-h2, static-h2 (ALPN picks h2)
    //          and HTTP/3 over QUIC on the       baseline-h3, static-h3
    //          same port number
    host.Bind(IPAddress.Any, 8081, certificate, httpProtocols: HttpProtocols.Http1);
    host.Bind(IPAddress.Any, 8443, certificate, httpProtocols: HttpProtocols.All);
}

await host.RunAsync();
