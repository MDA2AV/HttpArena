using System.Buffers.Text;
using System.Text;
using System.Text.Unicode;

using ioxide;
using ioxide.tls;

namespace Edixoi;

/// <summary>
/// Where a response goes. Plaintext writes land in the connection's write slab; a TLS connection
/// encrypts into the same slab through its session. One indirection here rather than a second
/// copy of every endpoint, and it is what lets one router answer on both doors.
/// </summary>
internal readonly struct Sink(TcpConnection connection, TlsSession? tls)
{
    public void Write(ReadOnlySpan<byte> bytes)
    {
        if (tls is null)
        {
            connection.Write(bytes);
        }
        else
        {
            tls.Write(connection, bytes);
        }
    }
}

/// <summary>
/// The HTTP/1.1 half of the entry: parse whole requests out of a byte span, answer them, and say
/// how much was consumed. Everything here is synchronous - the reads, the send and the one wait
/// are the caller's, so this never touches the ring.
///
///     GET|POST /baseline11?a=&amp;b=   text/plain, a + b (+ body)
///     GET      /json/{count}?m=N       application/json, total = price * quantity * N
///     POST     /echo                   the request body, byte for byte
///     GET      /delay/{ms}             text/plain, {ms}, after waiting that long
///
/// The delay is the one thing this cannot finish on its own: it hands the caller the milliseconds
/// and the caller, which can await, does the waiting and writes the answer.
/// </summary>
internal sealed class Http1(Dataset dataset)
{
    /// <summary>Cap on one request's head, so a peer that never sends CRLFCRLF cannot grow the carry.</summary>
    public const int MaxHeadBytes = 16 * 1024;

    /// <summary>The same for a declared body length, which is a number the peer chooses.</summary>
    private const int MaxBodyBytes = 1 << 20;

    // What ReadChunked reports when it did not read a body.
    private const int Incomplete = -1;   // the rest is still on its way
    private const int Malformed  = -2;   // it is never going to arrive

    /// <summary>No request asked to be delayed. Distinct from a delay of zero, which is one.</summary>
    public const int NoDelay = -1;

    private static readonly byte[] BadRequest =
        Encoding.ASCII.GetBytes("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");

    private static readonly byte[] NotFound =
        Encoding.ASCII.GetBytes("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");

    // One pair per connection. Both exist because a Content-Length has to be written before the
    // bytes it counts: an upload has to be decoded before it can be echoed, and a JSON body has
    // to be built before it can be sent. They are separate so that echoing a chunked upload
    // cannot be clobbered by the response assembled over it.
    private readonly Growable _upload = new();
    private readonly Growable _response = new();

    /// <summary>
    /// Answer every complete request in <paramref name="input"/> and return the bytes consumed.
    /// Stops early when a request asks to be delayed, leaving the wait in
    /// <paramref name="delayMs"/> for the caller to serve; what is left is a partial request.
    ///
    /// <paramref name="delayMs"/> is -1 for "nothing to wait on", not 0: <c>/delay/0</c> is a
    /// request the profile makes, and answering it is not the same as not having been asked.
    /// </summary>
    public int Serve(Sink sink, ReadOnlySpan<byte> input, ref bool close, out int delayMs)
    {
        int consumed = 0;
        delayMs = NoDelay;

        while (!close && delayMs == NoDelay)
        {
            int taken = ServeOne(sink, input[consumed..], ref close, out delayMs);
            if (taken == 0)
            {
                break;   // incomplete: wait for more bytes
            }

            consumed += taken;
        }

        return consumed;
    }

    /// <summary>Bytes consumed by one request, or 0 when it has not all arrived yet.</summary>
    private int ServeOne(Sink sink, ReadOnlySpan<byte> request, ref bool close, out int delayMs)
    {
        delayMs = NoDelay;

        int headEnd = request.IndexOf("\r\n\r\n"u8);
        if (headEnd < 0)
        {
            if (request.Length > MaxHeadBytes)
            {
                Fail(sink, ref close);
            }
            return 0;
        }

        ReadOnlySpan<byte> head = request[..headEnd];
        int bodyStart = headEnd + 4;

        int lineEnd = head.IndexOf("\r\n"u8);
        ReadOnlySpan<byte> line = lineEnd < 0 ? head : head[..lineEnd];

        if (!TryReadTarget(line, out ReadOnlySpan<byte> path, out ReadOnlySpan<byte> query))
        {
            Fail(sink, ref close);
            return request.Length;
        }

        ReadHeaders(lineEnd < 0 ? default : head[(lineEnd + 2)..],
                    out int contentLength, out bool chunked, out bool wantsClose);

        // The body, decoded. Chunked uploads land in the scratch so /echo can send them back and
        // /baseline11 can read their digits; a Content-Length body is already contiguous.
        ReadOnlySpan<byte> body;
        int bodyLength;

        int wireLength;

        if (chunked)
        {
            bodyLength = ReadChunked(request[bodyStart..], _upload, out wireLength);
            if (bodyLength == Incomplete)
            {
                return 0;
            }
            if (bodyLength == Malformed)
            {
                Fail(sink, ref close);
                return request.Length;
            }
            body = _upload.Span;
        }
        else
        {
            // Unsigned and bounded before it is used as a length: it came off the wire.
            if ((uint)contentLength > MaxBodyBytes)
            {
                Fail(sink, ref close);
                return request.Length;
            }

            if (request.Length - bodyStart < contentLength)
            {
                return 0;
            }

            bodyLength = contentLength;
            wireLength = contentLength;
            body = request.Slice(bodyStart, contentLength);
        }

        // Only now, with the whole request in hand. Applying it while parsing the head would
        // half-close the socket on a request whose body is still on its way.
        close = wantsClose;

        Route(sink, path, query, body, close, out delayMs);

        return bodyStart + wireLength;
    }

    private void Route(Sink sink, ReadOnlySpan<byte> path, ReadOnlySpan<byte> query,
                       ReadOnlySpan<byte> body, bool close, out int delayMs)
    {
        delayMs = NoDelay;

        if (path.SequenceEqual("/baseline11"u8))
        {
            WriteText(sink, Sum(query) + Digits(body), close);
            return;
        }

        if (path.SequenceEqual("/echo"u8))
        {
            WriteBody(sink, "application/octet-stream"u8, body, close);
            return;
        }

        // /json/{count}?m=N and /delay/{ms} both carry their argument in the path.
        if (TrySegment(path, "/json/"u8, out ReadOnlySpan<byte> countText))
        {
            Utf8Parser.TryParse(countText, out int count, out _);
            long multiplier = Value(query, "m"u8, fallback: 1);
            WriteBody(sink, "application/json"u8, WriteJson(count, multiplier), close);
            return;
        }

        if (TrySegment(path, "/delay/"u8, out ReadOnlySpan<byte> msText) &&
            Utf8Parser.TryParse(msText, out int ms, out _) && ms >= 0)
        {
            // Handed back rather than served: the wait belongs on the ring, and only the caller
            // can await it. It writes the answer once the timer fires.
            delayMs = ms;
            return;
        }

        sink.Write(NotFound);
    }

    private ReadOnlySpan<byte> WriteJson(int count, long multiplier)
    {
        dataset.Write(_response, count, multiplier);
        return _response.Span;
    }

    /// <summary>The delay profile's answer, written by the caller once its wait is over.</summary>
    public static void WriteDelayed(Sink sink, int ms, bool close) => WriteText(sink, ms, close);

    // ── request line ─────────────────────────────────────────────────────────────────────────

    /// <summary>Split "GET /json/5?m=7 HTTP/1.1" into its path and its query string.</summary>
    private static bool TryReadTarget(ReadOnlySpan<byte> line, out ReadOnlySpan<byte> path, out ReadOnlySpan<byte> query)
    {
        path = default;
        query = default;

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

        int mark = target.IndexOf((byte)'?');
        if (mark < 0)
        {
            path = target;
            return true;
        }

        path = target[..mark];
        query = target[(mark + 1)..];
        return true;
    }

    /// <summary>"/json/5" against "/json/" gives "5".</summary>
    private static bool TrySegment(ReadOnlySpan<byte> path, ReadOnlySpan<byte> prefix, out ReadOnlySpan<byte> rest)
    {
        if (path.StartsWith(prefix))
        {
            rest = path[prefix.Length..];
            return !rest.IsEmpty;
        }

        rest = default;
        return false;
    }

    /// <summary>Every value in the query string, added up - which is what /baseline11 answers.</summary>
    private static long Sum(ReadOnlySpan<byte> query)
    {
        long sum = 0;

        while (!query.IsEmpty)
        {
            int amp = query.IndexOf((byte)'&');
            ReadOnlySpan<byte> pair = amp < 0 ? query : query[..amp];
            query = amp < 0 ? default : query[(amp + 1)..];

            int equals = pair.IndexOf((byte)'=');
            if (equals >= 0 && Utf8Parser.TryParse(pair[(equals + 1)..], out long value, out _))
            {
                sum += value;
            }
        }

        return sum;
    }

    /// <summary>One named query value, for the /json multiplier.</summary>
    private static long Value(ReadOnlySpan<byte> query, ReadOnlySpan<byte> name, long fallback)
    {
        while (!query.IsEmpty)
        {
            int amp = query.IndexOf((byte)'&');
            ReadOnlySpan<byte> pair = amp < 0 ? query : query[..amp];
            query = amp < 0 ? default : query[(amp + 1)..];

            int equals = pair.IndexOf((byte)'=');
            if (equals >= 0 && pair[..equals].SequenceEqual(name) &&
                Utf8Parser.TryParse(pair[(equals + 1)..], out long value, out _))
            {
                return value;
            }
        }

        return fallback;
    }

    // ── headers and body ─────────────────────────────────────────────────────────────────────

    /// <summary>
    /// The three header fields these endpoints read. Field names are case-insensitive (RFC 9110
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
    /// Decode a chunked body into <paramref name="into"/> and return its decoded length, or
    /// <see cref="Incomplete"/> / <see cref="Malformed"/>. Telling those two apart is what stops
    /// a chunk size of ffffffff being waited on forever. <paramref name="wireLength"/> is what
    /// the framing occupied, which is what the caller skips to reach the next request - one walk
    /// answers both, so the two cannot disagree.
    /// </summary>
    private static int ReadChunked(ReadOnlySpan<byte> body, Growable into, out int wireLength)
    {
        into.Reset();
        wireLength = 0;
        int at = 0;

        while (true)
        {
            int end = body[at..].IndexOf("\r\n"u8);
            if (end < 0)
            {
                return Incomplete;
            }

            // The size line may carry a chunk extension ("2;name=value"), which TryParse stops at
            // and this ignores, as every server here does.
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

                wireLength = at + trailer + 2;
                return into.Length;
            }

            if (body.Length - at < size + 2)
            {
                return Incomplete;
            }

            into.Append(body.Slice(at, size));
            at += size + 2;
        }
    }

    /// <summary>
    /// A body that is a decimal number, as /baseline11's is. Anything that is not a digit is not
    /// part of that number and is skipped.
    /// </summary>
    private static long Digits(ReadOnlySpan<byte> body)
    {
        long value = 0;

        foreach (byte b in body)
        {
            if ((uint)(b - (byte)'0') <= 9)
            {
                value = (value * 10) + (b - (byte)'0');
            }
        }

        return value;
    }

    // ── responses ────────────────────────────────────────────────────────────────────────────

    private static void WriteText(Sink sink, long value, bool close)
    {
        Span<byte> body = stackalloc byte[20];
        Utf8Formatter.TryFormat(value, body, out int bodyLength);
        WriteBody(sink, "text/plain"u8, body[..bodyLength], close);
    }

    private static void WriteBody(Sink sink, ReadOnlySpan<byte> contentType, ReadOnlySpan<byte> body, bool close)
    {
        Span<byte> head = stackalloc byte[160];
        Utf8.TryWrite(head,
            $"HTTP/1.1 200 OK\r\nContent-Type: {contentType}\r\nContent-Length: {body.Length}\r\n{(close ? "Connection: close\r\n" : "")}\r\n",
            out int headLength);

        sink.Write(head[..headLength]);
        sink.Write(body);
    }

    private static void Fail(Sink sink, ref bool close)
    {
        sink.Write(BadRequest);
        close = true;
    }
}
