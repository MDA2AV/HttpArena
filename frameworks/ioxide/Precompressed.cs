using System.Buffers;
using System.Text;

namespace IoxideArena;

/// <summary>
/// Precompressed static variants, baked in the HTTP entry - ioxide.file serves the identity bytes;
/// content negotiation is HTTP, so it lives here, not in the runtime. For each base file that has a
/// .br/.gz sibling the whole response (base content-type, Content-Encoding, Vary, Content-Length,
/// body) is baked once at startup and chosen per request by Accept-Encoding (br > gzip). A request
/// the client can't take compressed falls back to ioxide.file's identity asset.
/// </summary>
internal sealed class Precompressed
{
    private readonly record struct Variant(byte[]? Br, byte[]? Gz);

    private readonly Dictionary<string, Variant> _byPath = new(StringComparer.Ordinal);
    private readonly Dictionary<string, Variant>.AlternateLookup<ReadOnlySpan<char>> _lookup;

    public int Count { get; }

    public Precompressed(string staticDir)
    {
        string root = Path.GetFullPath(staticDir);
        foreach (string path in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
        {
            if (path.EndsWith(".br", StringComparison.Ordinal) || path.EndsWith(".gz", StringComparison.Ordinal))
            {
                continue;   // bases only; .br/.gz are looked up as siblings
            }
            string url = "/" + Path.GetRelativePath(root, path).Replace('\\', '/');
            string contentType = MimeFor(path);
            byte[]? br = File.Exists(path + ".br") ? Bake(File.ReadAllBytes(path + ".br"), contentType, "br") : null;
            byte[]? gz = File.Exists(path + ".gz") ? Bake(File.ReadAllBytes(path + ".gz"), contentType, "gzip") : null;
            if (br != null || gz != null)
            {
                _byPath[url] = new Variant(br, gz);
            }
        }
        _lookup = _byPath.GetAlternateLookup<ReadOnlySpan<char>>();
        Count = _byPath.Count;
    }

    /// <summary>Best accepted precompressed response for the URL (br &gt; gzip), or null to use identity.</summary>
    public byte[]? Negotiate(ReadOnlySpan<byte> urlPath, bool acceptBr, bool acceptGzip)
    {
        if (urlPath.Length is 0 or > 1024)
        {
            return null;
        }
        Span<char> chars = stackalloc char[urlPath.Length];
        if (Ascii.ToUtf16(urlPath, chars, out int n) != OperationStatus.Done)
        {
            return null;
        }
        if (!_lookup.TryGetValue(chars[..n], out Variant v))
        {
            return null;
        }
        if (acceptBr && v.Br != null) return v.Br;
        if (acceptGzip && v.Gz != null) return v.Gz;
        return null;
    }

    private static byte[] Bake(byte[] body, string contentType, string encoding)
    {
        string head = $"HTTP/1.1 200 OK\r\nContent-Type: {contentType}\r\n" +
                      $"Content-Encoding: {encoding}\r\nVary: Accept-Encoding\r\nContent-Length: {body.Length}\r\n\r\n";
        byte[] header = Encoding.ASCII.GetBytes(head);
        var response = new byte[header.Length + body.Length];
        header.CopyTo(response, 0);
        body.CopyTo(response, header.Length);
        return response;
    }

    private static string MimeFor(string path) => Path.GetExtension(path) switch
    {
        ".html"  => "text/html",
        ".css"   => "text/css",
        ".js"    => "application/javascript",
        ".json"  => "application/json",
        ".svg"   => "image/svg+xml",
        ".png"   => "image/png",
        ".webp"  => "image/webp",
        ".woff2" => "font/woff2",
        ".txt"   => "text/plain",
        _        => "application/octet-stream",
    };
}
