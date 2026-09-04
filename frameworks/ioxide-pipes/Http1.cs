using System.Buffers;
using System.Buffers.Text;
using System.IO.Pipelines;
using System.Text;
using System.Text.Unicode;

using Glyph11;
using Glyph11.Parser;
using Glyph11.Parser.FlexibleParser;
using Glyph11.Protocol;
using Glyph11.Validation;

namespace IoxidePipes;

/// <summary>
/// The HTTP/1.1 half of the entry: Glyph11 does the parsing, this decides what to answer.
///
/// Both halves work in <see cref="ReadOnlySequence{T}"/>, which is what makes them fit. A
/// <see cref="PipeReader"/> hands over exactly that - a request split across two reads arrives as
/// two segments - and Glyph11 takes it as-is, so a partial request is held by the reader rather
/// than copied into a buffer of ours. The library also owns the two places a hand-written parser
/// gets fiddly: the query string, already split into <see cref="BinaryRequest.QueryParameters"/>,
/// and chunked framing, walked a chunk at a time without linearizing.
///
///     GET|POST /baseline11?a=&amp;b=   text/plain, a + b (+ body)
///     GET      /json/{count}?m=N       application/json, total = price * quantity * N
///     POST     /echo                   the request body, byte for byte
///     GET      /delay/{ms}             text/plain, {ms}, after waiting that long
///
/// The output is a <see cref="PipeWriter"/> and nothing here knows whether TLS is under it, which
/// is why the same routing serves the plaintext door and the TLS one unchanged.
///
/// One instance per connection: <see cref="BinaryRequest"/> is cleared and refilled per request
/// rather than allocated.
/// </summary>
internal sealed class Http1(Dataset dataset) : IDisposable
{
    /// <summary>Cap on one request's head, so a peer that never sends CRLFCRLF cannot buffer forever.</summary>
    private const int MaxHeadBytes = 16 * 1024;

    /// <summary>The same for a declared body length, which is a number the peer chooses.</summary>
    private const long MaxBodyBytes = 1 << 20;

    /// <summary>No request asked to be delayed. Distinct from a delay of zero, which is one.</summary>
    public const int NoDelay = -1;

    private static readonly byte[] BadRequest =
        Encoding.ASCII.GetBytes("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");

    private static readonly byte[] NotFound =
        Encoding.ASCII.GetBytes("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");

    private readonly BinaryRequest _request = new();
    private readonly Growable _response = new();

    public void Dispose() => _request.Dispose();

    /// <summary>
    /// Answer every complete request in <paramref name="input"/> and return where that left off.
    /// The caller passes it to AdvanceTo, and the reader keeps whatever is past it. Stops early
    /// when a request asks to be delayed, leaving the wait in <paramref name="delayMs"/>.
    /// </summary>
    public SequencePosition Serve(PipeWriter output, in ReadOnlySequence<byte> input, ref bool close, out int delayMs)
    {
        SequencePosition consumed = input.Start;
        delayMs = NoDelay;

        while (!close && delayMs == NoDelay)
        {
            ReadOnlySequence<byte> rest = input.Slice(consumed);
            long used = ServeOne(output, rest, ref close, out delayMs);
            if (used == 0)
            {
                break;   // incomplete: the reader holds it until the next read completes it
            }

            consumed = rest.GetPosition(used);
        }

        return consumed;
    }

    /// <summary>Bytes used by one request, or 0 when it has not all arrived yet.</summary>
    private long ServeOne(PipeWriter output, in ReadOnlySequence<byte> input, ref bool close, out int delayMs)
    {
        delayMs = NoDelay;
        _request.Clear();

        // Taken by ref, so it gets a local of its own rather than the caller's.
        ReadOnlySequence<byte> head = input;
        if (!FlexibleParser.TryExtractFullHeader(ref head, _request, out int headIndex))
        {
            if (input.Length > MaxHeadBytes)
            {
                Fail(output, ref close);
            }
            return 0;
        }

        // Glyph11 reports the last index of the head, not its length.
        long headBytes = headIndex + 1;
        ReadOnlySequence<byte> rawBody = input.Slice(headBytes);

        // Routed before the body is read, so a 100 KB echo is not also walked for digits it has
        // no use for.
        ReadOnlySpan<byte> path = _request.Path.Span;
        bool baseline = path.SequenceEqual("/baseline11"u8);
        bool echo = path.SequenceEqual("/echo"u8);

        BodyFramingResult framing = BodyFramingDetector.DetectBodyFraming(_request);
        long wireLength;
        long bodyLength;
        long digits = 0;

        switch (framing.Framing)
        {
            case BodyFraming.ContentLength:
                if ((ulong)framing.ContentLength > MaxBodyBytes)
                {
                    Fail(output, ref close);
                    return input.Length;
                }

                if (rawBody.Length < framing.ContentLength)
                {
                    return 0;
                }

                wireLength = bodyLength = framing.ContentLength;
                if (baseline)
                {
                    digits = Digits(rawBody.Slice(0, bodyLength), 0);
                }
                break;

            case BodyFraming.Chunked:
                try
                {
                    if (!TryWalkChunked(rawBody, baseline, ref digits, out wireLength, out bodyLength))
                    {
                        return 0;
                    }
                }
                catch (HttpParseException)
                {
                    // Glyph11 raises this for framing that can never become valid, so waiting for
                    // more of it would be waiting forever.
                    Fail(output, ref close);
                    return input.Length;
                }
                break;

            default:
                wireLength = bodyLength = 0;
                break;
        }

        // Only now, with the whole request in hand. Applying it while parsing the head would
        // half-close the socket on a request whose body is still on its way.
        close = WantsClose(_request);

        if (baseline)
        {
            WriteText(output, QuerySum(_request) + digits, close);
        }
        else if (echo)
        {
            WriteHead(output, "application/octet-stream"u8, bodyLength, close);
            WriteBody(output, rawBody, framing.Framing == BodyFraming.Chunked);
        }
        else if (TrySegment(path, "/json/"u8, out ReadOnlySpan<byte> countText))
        {
            Utf8Parser.TryParse(countText, out int count, out _);
            dataset.Write(_response, count, QueryValue(_request, "m"u8, fallback: 1));
            WriteHead(output, "application/json"u8, _response.Length, close);
            output.Write(_response.Span);
        }
        else if (TrySegment(path, "/delay/"u8, out ReadOnlySpan<byte> msText) &&
                 Utf8Parser.TryParse(msText, out int ms, out _) && ms >= 0)
        {
            // Handed back rather than served: the wait belongs on the ring, and only the caller
            // can await it. It writes the answer once the timer fires.
            delayMs = ms;
        }
        else
        {
            output.Write(NotFound);
        }

        return headBytes + wireLength;
    }

    /// <summary>The delay profile's answer, written by the caller once its wait is over.</summary>
    public static void WriteDelayed(PipeWriter output, int ms, bool close) => WriteText(output, ms, close);

    // ── body ─────────────────────────────────────────────────────────────────────────────────

    /// <summary>
    /// Walk a chunked body once, reporting what it occupied on the wire and what it decodes to -
    /// the caller needs both, and one walk means they cannot disagree. Digits are folded in only
    /// when the route is going to use them. False means the terminal chunk has not arrived; a
    /// body that can never be valid throws instead.
    /// </summary>
    private static bool TryWalkChunked(in ReadOnlySequence<byte> body, bool wantDigits, ref long digits,
                                       out long wireLength, out long bodyLength)
    {
        var chunks = new ChunkedBodyStream();
        long value = 0;
        wireLength = 0;
        bodyLength = 0;

        while (true)
        {
            ReadOnlySequence<byte> rest = body.Slice(wireLength);
            ChunkResult result = chunks.TryReadChunk(in rest, out long taken, out ReadOnlySequence<byte> data);
            wireLength += taken;

            switch (result)
            {
                case ChunkResult.Chunk:
                    bodyLength += data.Length;
                    if (wantDigits)
                    {
                        value = Digits(data, value);
                    }
                    break;

                case ChunkResult.Completed:
                    digits += value;
                    return true;

                default:
                    return false;
            }
        }
    }

    /// <summary>
    /// The body back out, straight from the reader's own segments - the chunked case decodes on
    /// the way rather than through a buffer of ours, which is what the multi-segment overload is
    /// for. The framing has already been validated by the walk above, so this one cannot fail.
    /// </summary>
    private static void WriteBody(PipeWriter output, in ReadOnlySequence<byte> body, bool chunked)
    {
        if (!chunked)
        {
            foreach (ReadOnlyMemory<byte> segment in body)
            {
                output.Write(segment.Span);
            }
            return;
        }

        var chunks = new ChunkedBodyStream();
        long at = 0;

        while (true)
        {
            ReadOnlySequence<byte> rest = body.Slice(at);
            ChunkResult result = chunks.TryReadChunk(in rest, out long taken, out ReadOnlySequence<byte> data);
            at += taken;

            if (result != ChunkResult.Chunk)
            {
                return;
            }

            foreach (ReadOnlyMemory<byte> segment in data)
            {
                output.Write(segment.Span);
            }
        }
    }

    /// <summary>
    /// A body that is a decimal number, as /baseline11's is, folded in across segments and across
    /// chunks. Anything that is not a digit is not part of that number and is skipped.
    /// </summary>
    private static long Digits(in ReadOnlySequence<byte> data, long value)
    {
        foreach (ReadOnlyMemory<byte> segment in data)
        {
            foreach (byte b in segment.Span)
            {
                if ((uint)(b - (byte)'0') <= 9)
                {
                    value = (value * 10) + (b - (byte)'0');
                }
            }
        }

        return value;
    }

    // ── request ──────────────────────────────────────────────────────────────────────────────

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

    /// <summary>Every query value added up, which is what /baseline11 answers.</summary>
    private static long QuerySum(BinaryRequest request)
    {
        long sum = 0;

        for (int i = 0; i < request.QueryParameters.Count; i++)
        {
            if (Utf8Parser.TryParse(request.QueryParameters[i].Value.Span, out long value, out _))
            {
                sum += value;
            }
        }

        return sum;
    }

    /// <summary>One named query value, for the /json multiplier.</summary>
    private static long QueryValue(BinaryRequest request, ReadOnlySpan<byte> name, long fallback)
    {
        for (int i = 0; i < request.QueryParameters.Count; i++)
        {
            KeyValuePair<ReadOnlyMemory<byte>, ReadOnlyMemory<byte>> pair = request.QueryParameters[i];
            if (pair.Key.Span.SequenceEqual(name) && Utf8Parser.TryParse(pair.Value.Span, out long value, out _))
            {
                return value;
            }
        }

        return fallback;
    }

    /// <summary>Field names are case-insensitive (RFC 9110 5.1) and both spellings are sent.</summary>
    private static bool WantsClose(BinaryRequest request)
    {
        for (int i = 0; i < request.Headers.Count; i++)
        {
            KeyValuePair<ReadOnlyMemory<byte>, ReadOnlyMemory<byte>> header = request.Headers[i];
            if (Ascii.EqualsIgnoreCase(header.Key.Span, "connection"u8))
            {
                return Ascii.EqualsIgnoreCase(header.Value.Span, "close"u8);
            }
        }

        return false;
    }

    // ── responses ────────────────────────────────────────────────────────────────────────────

    private static void WriteText(PipeWriter output, long value, bool close)
    {
        Span<byte> body = stackalloc byte[20];
        Utf8Formatter.TryFormat(value, body, out int bodyLength);
        WriteHead(output, "text/plain"u8, bodyLength, close);
        output.Write(body[..bodyLength]);
    }

    private static void WriteHead(PipeWriter output, ReadOnlySpan<byte> contentType, long length, bool close)
    {
        Span<byte> head = stackalloc byte[160];
        Utf8.TryWrite(head,
            $"HTTP/1.1 200 OK\r\nContent-Type: {contentType}\r\nContent-Length: {length}\r\n{(close ? "Connection: close\r\n" : "")}\r\n",
            out int headLength);

        output.Write(head[..headLength]);
    }

    private static void Fail(PipeWriter output, ref bool close)
    {
        output.Write(BadRequest);
        close = true;
    }
}
