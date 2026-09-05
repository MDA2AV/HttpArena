namespace SocketsArena;

/// <summary>
/// Decoding for <c>Transfer-Encoding: chunked</c> request bodies.
/// </summary>
/// <remarks>
/// A client that does not know its length ahead of time sends the body as size-prefixed chunks
/// instead, and the harness fragments those across TCP segments at every offset - so this reports
/// "not yet" rather than guessing whenever the terminator has not arrived, and the caller reads
/// more and asks again from the start.
/// </remarks>
internal static class Chunked
{
    /// <summary>
    /// Decodes into <paramref name="destination"/>. False means the body is incomplete and more
    /// bytes are needed; <paramref name="raw"/> is how much of the source the body occupied.
    /// </summary>
    public static bool TryDecode(ReadOnlySpan<byte> source, Span<byte> destination,
                                 out int decoded, out int raw, out bool overflow)
    {
        decoded = 0;
        raw = 0;
        overflow = false;

        var at = 0;

        while (true)
        {
            var lineEnd = source[at..].IndexOf("\r\n"u8);

            if (lineEnd < 0)
            {
                return false; // size line still arriving
            }

            var sizeLine = source.Slice(at, lineEnd);

            // A chunk extension follows a ';' and is not part of the size.
            var semicolon = sizeLine.IndexOf((byte)';');

            if (semicolon >= 0)
            {
                sizeLine = sizeLine[..semicolon];
            }

            if (!TryParseHex(sizeLine, out var size))
            {
                return false;
            }

            at += lineEnd + 2;

            if (size == 0)
            {
                // Trailers, then the final CRLF. Anything before it is a trailer line.
                while (true)
                {
                    var end = source[at..].IndexOf("\r\n"u8);

                    if (end < 0)
                    {
                        return false;
                    }

                    at += end + 2;

                    if (end == 0)
                    {
                        raw = at;
                        return true;
                    }
                }
            }

            if (source.Length - at < size + 2)
            {
                return false; // chunk body or its trailing CRLF still arriving
            }

            if (decoded + size > destination.Length)
            {
                overflow = true;
                return false; // caller grows the destination and retries
            }

            source.Slice(at, size).CopyTo(destination[decoded..]);

            decoded += size;
            at += size + 2;   // step over the chunk and its CRLF
        }
    }

    private static bool TryParseHex(ReadOnlySpan<byte> value, out int size)
    {
        size = 0;

        if (value.IsEmpty || value.Length > 8)
        {
            return false;
        }

        foreach (var c in value)
        {
            var digit = c switch
            {
                >= (byte)'0' and <= (byte)'9' => c - (byte)'0',
                >= (byte)'a' and <= (byte)'f' => c - (byte)'a' + 10,
                >= (byte)'A' and <= (byte)'F' => c - (byte)'A' + 10,
                _ => -1
            };

            if (digit < 0)
            {
                return false;
            }

            size = (size << 4) | digit;
        }

        return true;
    }
}
