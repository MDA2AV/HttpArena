using System.Security.Cryptography.X509Certificates;

namespace HttpArena;

/// <summary>
/// The server certificate, re-read from disk when the file underneath it
/// changes.
///
/// Kestrel's ServerCertificateSelector runs per handshake, so this is where a
/// rotation becomes visible without a restart: the selector asks for Current,
/// and Current notices the PEM was replaced. That is what the opt-in `tls`
/// profile checks -- a certificate is renewed roughly every 60 days in
/// production, and a server that needs a restart to pick one up is a weaker
/// server.
///
/// The mtime check is throttled rather than run on every handshake. A stat is
/// cheap next to a TLS handshake, but not next to a resumed one, and a second
/// of staleness costs nothing when the thing being tracked changes every two
/// months.
/// </summary>
internal sealed class RotatingCertificate : IDisposable
{
    private const int CheckIntervalMs = 1000;

    private readonly string _certPath;
    private readonly string _keyPath;
    private readonly object _gate = new();

    private X509Certificate2 _current;
    private DateTime _loadedStamp;
    private long _lastCheck;

    public RotatingCertificate(string certPath, string keyPath)
    {
        _certPath = certPath;
        _keyPath = keyPath;
        _current = Load(certPath, keyPath);
        _loadedStamp = Stamp(certPath, keyPath);
        _lastCheck = Environment.TickCount64;
    }

    public X509Certificate2 Current
    {
        get
        {
            var now = Environment.TickCount64;
            if (now - Interlocked.Read(ref _lastCheck) >= CheckIntervalMs)
            {
                Interlocked.Exchange(ref _lastCheck, now);
                ReloadIfChanged();
            }
            return Volatile.Read(ref _current);
        }
    }

    private void ReloadIfChanged()
    {
        try
        {
            var stamp = Stamp(_certPath, _keyPath);
            if (stamp == _loadedStamp) return;

            lock (_gate)
            {
                if (stamp == _loadedStamp) return;
                // A rotation is two files. Loading between the two writes gives
                // a mismatched pair, so a failure here is left for the next
                // check rather than thrown at a handshake in progress.
                var fresh = Load(_certPath, _keyPath);
                var previous = _current;
                Volatile.Write(ref _current, fresh);
                _loadedStamp = stamp;
                previous.Dispose();
            }
        }
        catch
        {
            // Keep serving the certificate that works.
        }
    }

    private static DateTime Stamp(string certPath, string keyPath)
    {
        var c = File.GetLastWriteTimeUtc(certPath);
        var k = File.GetLastWriteTimeUtc(keyPath);
        return c > k ? c : k;
    }

    private static X509Certificate2 Load(string certPath, string keyPath)
    {
        // CreateFromPemFile hands back a certificate whose key is ephemeral,
        // which SslStream will not use on every platform; the PKCS12 round trip
        // gives it one it will.
        using var pem = X509Certificate2.CreateFromPemFile(certPath, keyPath);
        return X509CertificateLoader.LoadPkcs12(pem.Export(X509ContentType.Pkcs12), null);
    }

    public void Dispose() => _current.Dispose();
}
