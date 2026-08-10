using System.Text;
using ioxide.http2;
using ioxide.nghttp3;
using ioxide.tls;

using Headers = System.ReadOnlySpan<System.Collections.Generic.KeyValuePair<System.ReadOnlyMemory<byte>, System.ReadOnlyMemory<byte>>>;

namespace IoxideArena;

/// <summary>The h2 TLS context (ALPN "h2", port 8443), held per reactor next to the h1 one.</summary>
internal sealed record H2Tls(TlsService Service);

/// <summary>
/// Routes shared by the h2 (:8443/tcp) and h3 (:8443/udp) servers: /baseline2 and /static/*.
/// Static assets are cached at startup with their precompressed .br/.gz variants and content
/// type, and served by Accept-Encoding - the same negotiation the h1 static path does.
/// </summary>
internal static class Multiplexed
{
    private readonly record struct Asset(byte[] Body, byte[]? Br, byte[]? Gz, byte[] Type);

    private static readonly Dictionary<string, Asset> Assets = new(StringComparer.Ordinal);
    private static Dictionary<string, Asset>.AlternateLookup<ReadOnlySpan<char>> _lookup;

    private static readonly byte[] ContentType = "content-type"u8.ToArray();
    private static readonly byte[] ContentEncoding = "content-encoding"u8.ToArray();
    private static readonly byte[] AcceptEncoding = "accept-encoding"u8.ToArray();
    private static readonly byte[] BrToken = "br"u8.ToArray();
    private static readonly byte[] GzipToken = "gzip"u8.ToArray();
    private static readonly byte[] TextPlain = "text/plain"u8.ToArray();
    private static readonly byte[] NotFound = "not found"u8.ToArray();

    public static void Init(string? staticRoot)
    {
        if (staticRoot != null)
        {
            var acc = new Dictionary<string, (byte[]? Body, byte[]? Br, byte[]? Gz)>(StringComparer.Ordinal);

            foreach (var file in Directory.EnumerateFiles(staticRoot, "*", SearchOption.AllDirectories))
            {
                var rel = Path.GetRelativePath(staticRoot, file).Replace('\\', '/');
                var bytes = File.ReadAllBytes(file);

                if (rel.EndsWith(".br", StringComparison.Ordinal))
                {
                    var b = rel[..^3];
                    acc[b] = acc.GetValueOrDefault(b) with { Br = bytes };
                }
                else if (rel.EndsWith(".gz", StringComparison.Ordinal))
                {
                    var b = rel[..^3];
                    acc[b] = acc.GetValueOrDefault(b) with { Gz = bytes };
                }
                else
                {
                    acc[rel] = acc.GetValueOrDefault(rel) with { Body = bytes };
                }
            }

            foreach (var (name, v) in acc)
            {
                if (v.Body != null)
                {
                    Assets[name] = new Asset(v.Body, v.Br, v.Gz, TypeFor(name));
                }
            }
        }

        _lookup = Assets.GetAlternateLookup<ReadOnlySpan<char>>();
    }

    public static Http2Response RouteH2(Http2Request request)
    {
        var (status, body, type, encoding) = Route(request.Path.Span, request.Headers.AsSpan());
        var response = new Http2Response { Status = status, Body = body };
        response.Headers.Add(ContentType, type);
        if (encoding != null)
        {
            response.Headers.Add(ContentEncoding, encoding);
        }
        return response;
    }

    public static Nghttp3Response RouteH3(Nghttp3Request request)
    {
        var (status, body, type, encoding) = Route(request.Path.Span, request.Headers.AsSpan());
        var response = new Nghttp3Response { Status = status, Body = body };
        response.Headers.Add(ContentType, type);
        if (encoding != null)
        {
            response.Headers.Add(ContentEncoding, encoding);
        }
        return response;
    }

    private static (int Status, byte[] Body, byte[] Type, byte[]? Encoding) Route(ReadOnlySpan<byte> path, Headers headers)
    {
        if (path.StartsWith("/baseline2"u8))
        {
            return (200, Encoding.ASCII.GetBytes(SumQuery(path).ToString()), TextPlain, null);
        }

        if (path.StartsWith("/static/"u8))
        {
            var name = path[8..];
            int q = name.IndexOf((byte)'?');
            if (q >= 0)
            {
                name = name[..q];
            }

            Span<char> chars = stackalloc char[name.Length];
            Ascii.ToUtf16(name, chars, out int written);

            if (_lookup.TryGetValue(chars[..written], out var asset))
            {
                var (body, encoding) = Negotiate(headers, asset);
                return (200, body, asset.Type, encoding);
            }
        }

        return (404, NotFound, TextPlain, null);
    }

    // Serve the precompressed variant the client accepts, br preferred over gzip, else identity.
    private static (byte[] Body, byte[]? Encoding) Negotiate(Headers headers, in Asset asset)
    {
        bool br = false, gz = false;

        foreach (var header in headers)
        {
            // h2/h3 header names are lowercase by spec, so an ordinal compare is enough.
            if (header.Key.Span.SequenceEqual(AcceptEncoding))
            {
                var value = header.Value.Span;
                br = value.IndexOf(BrToken) >= 0;
                gz = value.IndexOf(GzipToken) >= 0;
                break;
            }
        }

        if (br && asset.Br != null)
        {
            return (asset.Br, BrToken);
        }
        if (gz && asset.Gz != null)
        {
            return (asset.Gz, GzipToken);
        }
        return (asset.Body, null);
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
        _ => TextPlain,
    };
}
