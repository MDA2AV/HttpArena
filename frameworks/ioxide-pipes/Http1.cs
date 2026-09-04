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
/// and chunked framing, streamed a chunk at a time without linearizing.
///
/// One endpoint, which is the whole profile:
///     GET|POST /baseline11?a=&amp;b=  ->  text/plain "a + b (+ body)"
///
/// One instance per connection: <see cref="BinaryRequest"/> is cleared and refilled per request
/// rather than allocated.
/// </summary>
internal sealed class Http1 : IDisposable
{
    /// <summary>Cap on one request's head, so a peer that never sends CRLFCRLF cannot buffer forever.</summary>
    private const int MaxHeadBytes = 16 * 1024;

    /// <summary>The same for a declared body length, which is a number the peer chooses.</summary>
    private const long MaxBodyBytes = 1 << 20;

    private static readonly byte[] BadRequest =
        Encoding.ASCII.GetBytes("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");

    private static readonly byte[] NotFound =
        Encoding.ASCII.GetBytes("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");

    private readonly BinaryRequest _request = new();

    public void Dispose() => _request.Dispose();

    /// <summary>
    /// Answer every complete request in <paramref name="input"/> and return where that left off.
    /// The caller passes it to AdvanceTo, and the reader keeps whatever is past it.
    /// </summary>
    public SequencePosition Serve(PipeWriter output, in ReadOnlySequence<byte> input, ref bool close)
    {
        SequencePosition consumed = input.Start;

        while (!close)
        {
            ReadOnlySequence<byte> rest = input.Slice(consumed);
            long used = ServeOne(output, rest, ref close);
            if (used == 0)
            {
                break;   // incomplete: the reader holds it until the next read completes it
            }

            consumed = rest.GetPosition(used);
        }

        return consumed;
    }

    /// <summary>Bytes used by one request, or 0 when it has not all arrived yet.</summary>
    private long ServeOne(PipeWriter output, in ReadOnlySequence<byte> input, ref bool close)
    {
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

        // The query string is already split, so the answer is a walk over it. These are slices of
        // the reader's own buffer, valid until the caller advances - which it does after this.
        long sum = 0;
        for (int i = 0; i < _request.QueryParameters.Count; i++)
        {
            if (Utf8Parser.TryParse(_request.QueryParameters[i].Value.Span, out long value, out _))
            {
                sum += value;
            }
        }

        ReadOnlySequence<byte> body = input.Slice(headBytes);
        BodyFramingResult framing = BodyFramingDetector.DetectBodyFraming(_request);
        long bodyBytes;

        switch (framing.Framing)
        {
            case BodyFraming.ContentLength:
                if ((ulong)framing.ContentLength > MaxBodyBytes)
                {
                    Fail(output, ref close);
                    return input.Length;
                }

                if (body.Length < framing.ContentLength)
                {
                    return 0;
                }

                bodyBytes = framing.ContentLength;

                // Seeded at 0, not at sum: these digits are their own number, added to the total
                // afterwards. Folding them into the running value would shift it a decimal place
                // per byte - 55 and a body of "20" would answer 5520.
                sum += Digits(body.Slice(0, bodyBytes), 0);
                break;

            case BodyFraming.Chunked:
                try
                {
                    if (!TryReadChunked(body, ref sum, out bodyBytes))
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
                bodyBytes = 0;
                break;
        }

        // Only now, with the whole request in hand. Applying it while parsing the head would
        // half-close the socket on a request whose body is still on its way.
        close = WantsClose(_request);

        if (_request.Path.Span.SequenceEqual("/baseline11"u8))
        {
            WriteSum(output, sum, close);
        }
        else
        {
            output.Write(NotFound);
        }

        return headBytes + bodyBytes;
    }

    /// <summary>
    /// Walk the chunked body one chunk at a time, adding its digits as they go. False means the
    /// terminal chunk has not arrived; a body that can never be valid throws instead.
    /// </summary>
    private static bool TryReadChunked(in ReadOnlySequence<byte> body, ref long sum, out long used)
    {
        var chunks = new ChunkedBodyStream();
        long value = 0;
        used = 0;

        while (true)
        {
            ReadOnlySequence<byte> rest = body.Slice(used);
            ChunkResult result = chunks.TryReadChunk(in rest, out long taken, out ReadOnlySequence<byte> data);
            used += taken;

            switch (result)
            {
                case ChunkResult.Chunk:
                    // The payload can straddle a read boundary, so the digits are taken from the
                    // sequence rather than a span - which is the point of the multi-segment overload.
                    value = Digits(data, value);
                    break;

                case ChunkResult.Completed:
                    sum += value;
                    return true;

                default:
                    return false;
            }
        }
    }

    /// <summary>
    /// The body is a decimal number, so it is never held: its digits are folded into the running
    /// value as they are seen, across segments and across chunks. Anything that is not a digit is
    /// not part of the number the endpoint is defined on, and is skipped.
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

    /// <summary>Stage the answer in the writer's own buffer; the caller flushes it.</summary>
    private static void WriteSum(PipeWriter output, long sum, bool close)
    {
        Span<byte> body = stackalloc byte[20];
        Utf8Formatter.TryFormat(sum, body, out int bodyLength);

        Span<byte> head = stackalloc byte[128];
        Utf8.TryWrite(head,
            $"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {bodyLength}\r\n{(close ? "Connection: close\r\n" : "")}\r\n",
            out int headLength);

        output.Write(head[..headLength]);
        output.Write(body[..bodyLength]);
    }

    private static void Fail(PipeWriter output, ref bool close)
    {
        output.Write(BadRequest);
        close = true;
    }
}
