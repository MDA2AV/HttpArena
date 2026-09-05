using System.Security.Cryptography.X509Certificates;

using SocketsArena;

// ─────────────────────────────────────────────────────────────────────────────────────────────
//  sockets - HTTP/1.1 written directly on System.Net.Sockets.
//
//  No server library above the socket: the request line and the three headers the profiles read
//  are parsed off the read buffer, and responses are appended to a write buffer that is flushed
//  once per batch. HTTP/1.1 cleartext only - HTTP/2 would mean HPACK and framing by hand and
//  HTTP/3 a QUIC stack, neither of which says anything more about the socket layer.
//
//    :8080  baseline, pipelined, limited-conn, async, latency-1m, latency-10k, json-comp
//    :8081  the same, over TLS - json-tls and 8gbit
// ─────────────────────────────────────────────────────────────────────────────────────────────

var port = int.TryParse(Environment.GetEnvironmentVariable("PORT"), out var p) ? p : 8080;

var listeners = int.TryParse(Environment.GetEnvironmentVariable("SOCKETS_LISTENERS"), out var l)
    ? l
    : Environment.ProcessorCount;

var dataset = new Dataset();

Server.Start(port, listeners, dataset);

// The harness mounts a certificate pair; without it only the cleartext listener comes up.
var certPath = Environment.GetEnvironmentVariable("TLS_CERT") ?? "/certs/server.crt";
var keyPath = Environment.GetEnvironmentVariable("TLS_KEY") ?? "/certs/server.key";
var secure = false;

if (File.Exists(certPath) && File.Exists(keyPath))
{
    // CreateFromPemFile leaves the private key ephemeral; SslStream wants one it can keep.
    using var pem = X509Certificate2.CreateFromPemFile(certPath, keyPath);
    var certificate = X509CertificateLoader.LoadPkcs12(pem.Export(X509ContentType.Pkcs12), null);

    Server.StartSecure(8081, listeners, dataset, certificate);
    secure = true;
}

Console.WriteLine($"[sockets] :{port}{(secure ? " + :8081 tls" : "")}, {listeners} listeners, dataset={(dataset.IsAvailable ? dataset.Count + " items" : "absent")}");

await Task.Delay(Timeout.Infinite);
