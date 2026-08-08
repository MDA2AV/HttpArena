using System.Text;
using ioxide.tls;

namespace IoxideArena;

/// <summary>The h2 TLS context (ALPN "h2", port 8443), held per reactor next to the h1 one.</summary>
internal sealed record H2Tls(TlsService Service);

/// <summary>
/// Routes shared by the h2 (:8443/tcp) and h3 (:8443/udp) servers: /baseline2 and /static/*.
/// Static bodies are cached at startup with their content type, keyed for span lookups.
/// </summary>
internal static class Multiplexed
{
    private static readonly Dictionary<string, (byte[] Body, byte[] Type)> Assets = new(StringComparer.Ordinal);
    private static Dictionary<string, (byte[] Body, byte[] Type)>.AlternateLookup<ReadOnlySpan<char>> _lookup;

    private static readonly byte[] ContentTypeName = "content-type"u8.ToArray();
    private static readonly byte[] TextPlain = "text/plain"u8.ToArray();
    private static readonly byte[] NotFound = "not found"u8.ToArray();

    public static void Init(string? staticRoot)
    {
        if (staticRoot != null)
        {
            foreach (var file in Directory.EnumerateFiles(staticRoot, "*", SearchOption.AllDirectories))
            {
                var rel = Path.GetRelativePath(staticRoot, file).Replace('\\', '/');
                Assets[rel] = (File.ReadAllBytes(file), TypeFor(rel));
            }
        }

        _lookup = Assets.GetAlternateLookup<ReadOnlySpan<char>>();
    }

    public static ioxide.nghttp2.Nghttp2Response RouteH2(ioxide.nghttp2.Nghttp2Request request)
    {
        var (status, body, type) = Route(request.Path.Span);
        var response = new ioxide.nghttp2.Nghttp2Response { Status = status, Body = body };
        response.Headers.Add(ContentTypeName, type);
        return response;
    }

    public static ioxide.nghttp3.Nghttp3Response RouteH3(ioxide.nghttp3.Nghttp3Request request)
    {
        var (status, body, type) = Route(request.Path.Span);
        var response = new ioxide.nghttp3.Nghttp3Response { Status = status, Body = body };
        response.Headers.Add(ContentTypeName, type);
        return response;
    }

    private static (int Status, byte[] Body, byte[] Type) Route(ReadOnlySpan<byte> path)
    {
        if (path.StartsWith("/baseline2"u8))
        {
            long sum = SumQuery(path);
            return (200, Encoding.ASCII.GetBytes(sum.ToString()), TextPlain);
        }

        if (path.StartsWith("/static/"u8))
        {
            var name = path[8..];
            Span<char> chars = stackalloc char[name.Length];
            System.Text.Ascii.ToUtf16(name, chars, out int written);

            if (_lookup.TryGetValue(chars[..written], out var asset))
            {
                return (200, asset.Body, asset.Type);
            }
        }

        return (404, NotFound, TextPlain);
    }

    // "?a=1&b=1" - every value after '=' up to the next '&' is an int; anything else is 0.
    private static long SumQuery(ReadOnlySpan<byte> path)
    {
        int q = path.IndexOf((byte)'?');
        if (q < 0)
        {
            return 0;
        }

        long sum = 0;
        var rest = path[(q + 1)..];

        while (!rest.IsEmpty)
        {
            int amp = rest.IndexOf((byte)'&');
            var pair = amp < 0 ? rest : rest[..amp];
            rest = amp < 0 ? default : rest[(amp + 1)..];

            int eq = pair.IndexOf((byte)'=');
            if (eq >= 0 && System.Buffers.Text.Utf8Parser.TryParse(pair[(eq + 1)..], out long value, out _))
            {
                sum += value;
            }
        }

        return sum;
    }

    private static byte[] TypeFor(string name) => Path.GetExtension(name) switch
    {
        ".html" => "text/html"u8.ToArray(),
        ".css" => "text/css"u8.ToArray(),
        ".js" => "text/javascript"u8.ToArray(),
        ".json" => "application/json"u8.ToArray(),
        ".svg" => "image/svg+xml"u8.ToArray(),
        ".webp" => "image/webp"u8.ToArray(),
        ".png" => "image/png"u8.ToArray(),
        ".woff2" => "font/woff2"u8.ToArray(),
        ".br" => "application/octet-stream"u8.ToArray(),
        ".gz" => "application/octet-stream"u8.ToArray(),
        _ => TextPlain,
    };
}
