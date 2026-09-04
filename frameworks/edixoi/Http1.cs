using System.Buffers.Text;
using System.Text;
using System.Text.Unicode;

using ioxide;

namespace Edixoi;

/// <summary>
/// The HTTP/1.1 half of the entry: parse whole requests out of a byte span, answer them, and say
/// how much was consumed. Everything here is synchronous and allocation-free - the reads and the
/// send are the caller's, so this never touches the ring.
///
/// One endpoint, which is the whole profile:
///     GET|POST /baseline11?a=&amp;b=  ->  text/plain "a + b (+ body)"
///
/// The body is a decimal number, so it is never held: <see cref="ReadChunked"/> accumulates its
/// digits as they arrive and there is nothing to reassemble afterwards.
/// </summary>
internal static class Http1
{
    /// <summary>Cap on one request's head, so a peer that never sends CRLFCRLF cannot grow the carry.</summary>
    public const int MaxHeadBytes = 16 * 1024;

    /// <summary>The same for a declared body length, which is a number the peer chooses.</summary>
    private const int MaxBodyBytes = 1 << 20;

    // What ReadChunked reports when it cannot return a length.
    private const int Incomplete = -1;   // the rest is still on its way
    private const int Malformed  = -2;   // it is never going to arrive

    private static readonly byte[] BadRequest =
        Encoding.ASCII.GetBytes("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");

    private static readonly byte[] NotFound =
        Encoding.ASCII.GetBytes("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");

    /// <summary>
    /// Answer every complete request in <paramref name="input"/> and return the bytes consumed.
    /// What is left is a partial request the caller holds until the next read completes it.
    /// </summary>
    public static int Serve(TcpConnection conn, ReadOnlySpan<byte> input, ref bool close)
    {
        int consumed = 0;

        while (!close)
        {
            int taken = ServeOne(conn, input[consumed..], ref close);
            if (taken == 0)
            {
                break;   // incomplete: wait for more bytes
            }

            consumed += taken;
        }

        return consumed;
    }

    /// <summary>Bytes consumed by one request, or 0 when it has not all arrived yet.</summary>
    private static int ServeOne(TcpConnection conn, ReadOnlySpan<byte> request, ref bool close)
    {
        int headEnd = request.IndexOf("\r\n\r\n"u8);
        if (headEnd < 0)
        {
            if (request.Length > MaxHeadBytes)
            {
                Fail(conn, ref close);
            }
            return 0;
        }

        ReadOnlySpan<byte> head = request[..headEnd];
        int bodyStart = headEnd + 4;

        int lineEnd = head.IndexOf("\r\n"u8);
        ReadOnlySpan<byte> line = lineEnd < 0 ? head : head[..lineEnd];

        if (!TryReadTarget(line, out ReadOnlySpan<byte> path, out long sum))
        {
            Fail(conn, ref close);
            return request.Length;
        }

        ReadHeaders(lineEnd < 0 ? default : head[(lineEnd + 2)..],
                    out int contentLength, out bool chunked, out bool wantsClose);

        int bodyLength;
        if (chunked)
        {
            bodyLength = ReadChunked(request[bodyStart..], ref sum);
            if (bodyLength == Incomplete)
            {
                return 0;
            }
            if (bodyLength == Malformed)
            {
                Fail(conn, ref close);
                return request.Length;
            }
        }
        else
        {
            // Unsigned and bounded before it is used as a length: it came off the wire.
            if ((uint)contentLength > MaxBodyBytes)
            {
                Fail(conn, ref close);
                return request.Length;
            }

            bodyLength = contentLength;
            if (request.Length - bodyStart < bodyLength)
            {
                return 0;
            }

            if (bodyLength > 0 && Utf8Parser.TryParse(request.Slice(bodyStart, bodyLength), out long body, out _))
            {
                sum += body;
            }
        }

        // Only now, with the whole request in hand. Applying it while parsing the head would
        // half-close the socket on a request whose body is still on its way.
        close = wantsClose;

        if (path.SequenceEqual("/baseline11"u8))
        {
            WriteSum(conn, sum, close);
        }
        else
        {
            conn.Write(NotFound);
        }

        return bodyStart + bodyLength;
    }

    /// <summary>
    /// Split "GET /baseline11?a=13&amp;b=42 HTTP/1.1" into its path and the sum of its query
    /// values. The values ARE the response, so they are added as they are found rather than
    /// collected first - the profile asks for their total and nothing else.
    /// </summary>
    private static bool TryReadTarget(ReadOnlySpan<byte> line, out ReadOnlySpan<byte> path, out long sum)
    {
        path = default;
        sum = 0;

        int afterMethod = line.IndexOf((byte)' ');
        if (afterMethod < 0)
        {
            return false;
        }

        ReadOnlySpan<byte> target = line[(afterMethod + 1)..];
        int afterTarget = target.IndexOf((byte)' ');
        if (afterTarget < 0)
        {
            return false;
        }

        target = target[..afterTarget];

        int query = target.IndexOf((byte)'?');
        if (query < 0)
        {
            path = target;
            return true;
        }

        path = target[..query];

        for (ReadOnlySpan<byte> rest = target[(query + 1)..]; !rest.IsEmpty;)
        {
            int amp = rest.IndexOf((byte)'&');
            ReadOnlySpan<byte> pair = amp < 0 ? rest : rest[..amp];
            rest = amp < 0 ? default : rest[(amp + 1)..];

            int equals = pair.IndexOf((byte)'=');
            if (equals >= 0 && Utf8Parser.TryParse(pair[(equals + 1)..], out long value, out _))
            {
                sum += value;
            }
        }

        return true;
    }

    /// <summary>
    /// The three header fields this endpoint reads. Field names are case-insensitive (RFC 9110
    /// 5.1) and the load generator sends both spellings, so every comparison here ignores case.
    /// </summary>
    private static void ReadHeaders(ReadOnlySpan<byte> headers, out int contentLength, out bool chunked, out bool close)
    {
        contentLength = 0;
        chunked = false;
        close = false;

        while (!headers.IsEmpty)
        {
            int end = headers.IndexOf("\r\n"u8);
            ReadOnlySpan<byte> header = end < 0 ? headers : headers[..end];
            headers = end < 0 ? default : headers[(end + 2)..];

            int colon = header.IndexOf((byte)':');
            if (colon < 0)
            {
                continue;
            }

            ReadOnlySpan<byte> name = header[..colon];
            ReadOnlySpan<byte> value = header[(colon + 1)..].Trim((byte)' ');

            if (Ascii.EqualsIgnoreCase(name, "content-length"u8))
            {
                Utf8Parser.TryParse(value, out contentLength, out _);
            }
            else if (Ascii.EqualsIgnoreCase(name, "transfer-encoding"u8))
            {
                chunked = Ascii.EqualsIgnoreCase(value, "chunked"u8);
            }
            else if (Ascii.EqualsIgnoreCase(name, "connection"u8))
            {
                close = Ascii.EqualsIgnoreCase(value, "close"u8);
            }
        }
    }

    /// <summary>
    /// Walk a chunked body, adding its digits to <paramref name="sum"/> as they go, and return
    /// its length on the wire - or <see cref="Incomplete"/> / <see cref="Malformed"/>. Telling
    /// those two apart is what stops a chunk size of ffffffff being waited on forever.
    /// </summary>
    private static int ReadChunked(ReadOnlySpan<byte> body, ref long sum)
    {
        long value = 0;
        int at = 0;

        while (true)
        {
            int end = body[at..].IndexOf("\r\n"u8);
            if (end < 0)
            {
                return Incomplete;
            }

            // The size line may carry a chunk extension ("2;name=value"), which TryParse stops
            // at and this ignores, as every server here does.
            if (!Utf8Parser.TryParse(body.Slice(at, end), out int size, out _, 'x') ||
                (uint)size > MaxBodyBytes)
            {
                return Malformed;
            }

            at += end + 2;

            if (size == 0)
            {
                // The trailer section, empty in everything this serves, ends with its own CRLF.
                int trailer = body[at..].IndexOf("\r\n"u8);
                if (trailer < 0)
                {
                    return Incomplete;
                }

                sum += value;
                return at + trailer + 2;
            }

            if (body.Length - at < size + 2)
            {
                return Incomplete;
            }

            foreach (byte digit in body.Slice(at, size))
            {
                value = (value * 10) + (digit - (byte)'0');
            }

            at += size + 2;
        }
    }

    /// <summary>Stage the answer into the connection's write slab; the caller sends it.</summary>
    private static void WriteSum(TcpConnection conn, long sum, bool close)
    {
        Span<byte> body = stackalloc byte[20];
        Utf8Formatter.TryFormat(sum, body, out int bodyLength);

        Span<byte> head = stackalloc byte[128];
        Utf8.TryWrite(head,
            $"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {bodyLength}\r\n{(close ? "Connection: close\r\n" : "")}\r\n",
            out int headLength);

        conn.Write(head[..headLength]);
        conn.Write(body[..bodyLength]);
    }

    private static void Fail(TcpConnection conn, ref bool close)
    {
        conn.Write(BadRequest);
        close = true;
    }
}
