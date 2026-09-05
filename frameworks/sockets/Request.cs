using System.Buffers.Text;

namespace SocketsArena;

internal enum Route : byte { Unknown, Pipeline, Baseline, Delay, Json, Echo }

/// <summary>
/// A parsed request line plus the four header values anything here actually needs.
/// </summary>
/// <remarks>
/// Headers are not collected into a dictionary. The profiles read Content-Length, Accept-Encoding
/// and Connection and nothing else, so the parse looks for those three by name and steps over the
/// rest without touching their bytes. Everything is a span over the read buffer - no substring, no
/// string at all on the request path.
/// </remarks>
/// <remarks>Value fields only, so it can be carried across the awaits a body read or a delay needs.</remarks>
internal struct Request
{
    public Route Route;
    public bool KeepAlive;
    public bool AcceptsBrotli;
    public bool AcceptsGzip;
    public int ContentLength;
    public bool Chunked;
    public int DelayMs;
    public int A;              // baseline: ?a=  |  json: count
    public int B;              // baseline: ?b=  |  json: ?m=

    public static bool TryParse(ReadOnlySpan<byte> buffer, out Request request, out int headerLength)
    {
        request = default;
        headerLength = 0;

        var end = buffer.IndexOf("\r\n\r\n"u8);

        if (end < 0)
        {
            return false;
        }

        headerLength = end + 4;

        var head = buffer[..end];

        var lineEnd = head.IndexOf("\r\n"u8);
        var line = lineEnd < 0 ? head : head[..lineEnd];

        var methodEnd = line.IndexOf((byte)' ');

        if (methodEnd < 0)
        {
            return false;
        }

        var isPost = line[..methodEnd].SequenceEqual("POST"u8);
        var afterMethod = line[(methodEnd + 1)..];

        var targetEnd = afterMethod.IndexOf((byte)' ');
        var target = targetEnd < 0 ? afterMethod : afterMethod[..targetEnd];

        // HTTP/1.1 keeps the connection unless told otherwise; 1.0 is the other way round.
        request.KeepAlive = !afterMethod.EndsWith("HTTP/1.0"u8);

        ParseTarget(target, ref request);
        ParseHeaders(lineEnd < 0 ? default : head[(lineEnd + 2)..], ref request);

        if (!isPost)
        {
            request.ContentLength = 0;
            request.Chunked = false;
        }
        else if (request.Chunked)
        {
            request.ContentLength = 0;
        }

        return true;
    }

    private static void ParseTarget(ReadOnlySpan<byte> target, ref Request request)
    {
        var query = target.IndexOf((byte)'?');
        var path = query < 0 ? target : target[..query];

        if (path.StartsWith("/baseline11"u8) || path.StartsWith("/baseline2"u8))
        {
            request.Route = Route.Baseline;
        }
        else if (path.SequenceEqual("/pipeline"u8))
        {
            request.Route = Route.Pipeline;
        }
        else if (path.StartsWith("/delay/"u8))
        {
            if (Utf8Parser.TryParse(path[7..], out int ms, out var used) && used == path.Length - 7 && ms >= 0)
            {
                request.Route = Route.Delay;
                request.DelayMs = ms;
            }
        }
        else if (path.StartsWith("/json/"u8))
        {
            if (Utf8Parser.TryParse(path[6..], out int count, out var used) && used == path.Length - 6)
            {
                request.Route = Route.Json;
                request.A = count;
                request.B = 1;   // multiplier defaults to 1
            }
        }
        else if (path.SequenceEqual("/echo"u8))
        {
            request.Route = Route.Echo;
        }

        if (query >= 0)
        {
            ParseQuery(target[(query + 1)..], ref request);
        }
    }

    private static void ParseQuery(ReadOnlySpan<byte> query, ref Request request)
    {
        while (!query.IsEmpty)
        {
            var amp = query.IndexOf((byte)'&');
            var pair = amp < 0 ? query : query[..amp];

            var eq = pair.IndexOf((byte)'=');

            if (eq > 0 && Utf8Parser.TryParse(pair[(eq + 1)..], out int value, out _))
            {
                var name = pair[..eq];

                if (name.SequenceEqual("a"u8)) request.A = value;
                else if (name.SequenceEqual("b"u8)) request.B = value;
                else if (name.SequenceEqual("m"u8) && request.Route == Route.Json) request.B = value;
            }

            if (amp < 0) break;
            query = query[(amp + 1)..];
        }
    }

    private static void ParseHeaders(ReadOnlySpan<byte> headers, ref Request request)
    {
        while (!headers.IsEmpty)
        {
            var lineEnd = headers.IndexOf("\r\n"u8);
            var line = lineEnd < 0 ? headers : headers[..lineEnd];

            if (line.IsEmpty)
            {
                break;
            }

            var colon = line.IndexOf((byte)':');

            if (colon > 0)
            {
                var name = line[..colon];
                var value = line[(colon + 1)..].TrimStart((byte)' ');

                if (EqualsIgnoreCase(name, "content-length"u8))
                {
                    Utf8Parser.TryParse(value, out request.ContentLength, out _);
                }
                else if (EqualsIgnoreCase(name, "accept-encoding"u8))
                {
                    request.AcceptsBrotli = value.IndexOf("br"u8) >= 0;
                    request.AcceptsGzip = value.IndexOf("gzip"u8) >= 0;
                }
                else if (EqualsIgnoreCase(name, "transfer-encoding"u8))
                {
                    // Only chunked matters here: it is the one encoding that changes how the body
                    // is framed, and a length header is ignored when it is present (RFC 9112 6.3).
                    request.Chunked = value.IndexOf("chunked"u8) >= 0;
                }
                else if (EqualsIgnoreCase(name, "connection"u8))
                {
                    if (EqualsIgnoreCase(value, "close"u8)) request.KeepAlive = false;
                    else if (EqualsIgnoreCase(value, "keep-alive"u8)) request.KeepAlive = true;
                }
            }

            if (lineEnd < 0) break;
            headers = headers[(lineEnd + 2)..];
        }
    }

    // Header names are case-insensitive; the constants compared against are all lowercase.
    private static bool EqualsIgnoreCase(ReadOnlySpan<byte> value, ReadOnlySpan<byte> lowercase)
    {
        if (value.Length != lowercase.Length)
        {
            return false;
        }

        for (var i = 0; i < value.Length; i++)
        {
            var c = value[i];

            if (c is >= (byte)'A' and <= (byte)'Z')
            {
                c |= 0x20;
            }

            if (c != lowercase[i])
            {
                return false;
            }
        }

        return true;
    }
}
