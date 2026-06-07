// ReSharper disable always CheckNamespace
// ReSharper disable always SuggestVarOrType_BuiltInTypes
// (var is avoided intentionally in this project so that concrete types are visible at call sites.)
// ReSharper disable always StackAllocInsideLoop
// ReSharper disable always ClassCannotBeInstantiated

using System.Text;

#pragma warning disable CA2014

namespace Shrike;

// Very naive
internal static unsafe class HeaderParsing
{
    /// <summary>
    /// Finds the first occurrence of CRLFCRLF in a managed byte buffer slice [head..tail).
    /// Returns the absolute index (relative to buf) of the '\r' in the sequence, or -1 if not found.
    /// </summary>
    /// <remarks>
    /// Fast path: relies on <see cref="Span{T}.IndexOf(ReadOnlySpan{T})"/> which is vectorized on modern runtimes.
    /// The caller must ensure 0 ≤ head ≤ tail ≤ buf.Length.
    /// </remarks>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    internal static int FindCrlfCrlf(byte[] buf, int head, int tail)
    {
        int idx = buf.AsSpan(head, tail - head).IndexOf(CrlfCrlf);
        return idx >= 0 ? head + idx : -1;
    }
    
    /// <summary>
    /// Finds CRLFCRLF within an unmanaged region addressed by <paramref name="buf"/> in [head..tail).
    /// Returns the absolute index (relative to the same coordinate system as head/tail) of the '\r' or -1.
    /// </summary>
    /// <remarks>
    /// The caller must guarantee that the memory range [buf+head, buf+tail) is valid and readable.
    /// </remarks>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    internal static int FindCrlfCrlf(byte* buf, int head, int tail)
    {
        // Construct a Span<byte> view over the raw memory.
        // The caller must guarantee that (tail - head) bytes are valid and readable.
        var span = new ReadOnlySpan<byte>(buf + head, tail - head);

        int idx = span.IndexOf(CrlfCrlf);
        return idx >= 0 ? head + idx : -1;
    }
    
    /// <summary>
    /// Same as the unmanaged overload, but also returns a <see cref="ReadOnlySpan{Byte}"/> view over [head..tail).
    /// Useful to avoid reconstructing the span twice (for parsing the request-line after the sentinel is found).
    /// </summary>
    /// <param name="buf">Base pointer to the buffer.</param>
    /// <param name="head">Start offset (inclusive).</param>
    /// <param name="tail">End offset (exclusive).</param>
    /// <param name="idx">
    /// Out: absolute index of the '\r' starting the CRLFCRLF sentinel, or -1 if not found.
    /// </param>
    /// <returns>A span over the provided range [head..tail).</returns>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    internal static ReadOnlySpan<byte> FindCrlfCrlf(byte* buf, int head, int tail, ref int idx)
    {
        // Construct a Span<byte> view over the raw memory.
        // The caller must guarantee that (tail - head) bytes are valid and readable.
        var span = new ReadOnlySpan<byte>(buf + head, tail - head);

        idx = span.IndexOf(CrlfCrlf);
        if (idx >= 0)
            idx += head;
        else
            idx = -1;

        return span;
    }

    /// <summary>
    /// Extracts and hashes the HTTP request target from the request line (e.g., "GET /path?x=1 HTTP/1.1").
    /// Expects <paramref name="headerSpan"/> to begin at the start of the request line and contain at least
    /// the first CRLF. Throws <see cref="InvalidOperationException"/> if the request-line is malformed.
    /// </summary>
    /// <remarks>
    /// Parsing steps:
    ///   1) Find the first CRLF to isolate the request line.
    ///   2) Find first and second spaces: METHOD SP REQUEST-TARGET SP HTTP-VERSION.
    ///   3) Slice the REQUEST-TARGET and hash it with FNV-1a 32-bit.
    /// 
    /// Notes:
    ///   - The hash is over the raw byte sequence of the target (no decoding / normalization).
    ///   - Query string is preserved in the slice; callers can change hashing if they want to ignore it.
    /// </remarks>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    internal static uint ExtractRoute(ReadOnlySpan<byte> headerSpan)
    {
        var lineEnd = headerSpan.IndexOf(Crlf);
        var firstHeader = headerSpan[..lineEnd];

        var firstSpace = firstHeader.IndexOf(Space);
        if (firstSpace == -1)
            throw new InvalidOperationException("Invalid request line");
        
        var secondSpaceRelative = firstHeader[(firstSpace + 1)..].IndexOf(Space);
        if (secondSpaceRelative == -1)
            throw new InvalidOperationException("Invalid request line");

        var secondSpace = firstSpace + secondSpaceRelative + 1;
        
        // REQUEST-TARGET slice: may include path + query (e.g., "/foo?bar=baz")
        var url = firstHeader[(firstSpace + 1)..secondSpace];

        return Fnv1a32(url);
    }
    
    internal static BinaryH1HeaderData ExtractBinaryH1HeaderData(ReadOnlySpan<byte> headerSpan)
    {
        var headerData = new BinaryH1HeaderData();
        
        var lineEnd = headerSpan.IndexOf(Crlf);
        var firstHeader = headerSpan[..lineEnd];

        var firstSpace = firstHeader.IndexOf(Space);
        if (firstSpace == -1)
            throw new InvalidOperationException("Invalid request line");
        
        headerData.HttpMethod = new PinnedByteSequence(firstHeader[..firstSpace]);
        
        var secondSpaceRelative = firstHeader[(firstSpace + 1)..].IndexOf(Space);
        if (secondSpaceRelative == -1)
            throw new InvalidOperationException("Invalid request line");

        var secondSpace = firstSpace + secondSpaceRelative + 1;
        
        // REQUEST-TARGET slice: may include path + query (e.g., "/foo?bar=baz")
        var url = firstHeader[(firstSpace + 1)..secondSpace];

        var queryParamSeparator = url.IndexOf(Question);

        if (queryParamSeparator == -1)
        {
            headerData.Route = new PinnedByteSequence(url);
        }
        else
        {
            headerData.Route = new PinnedByteSequence(url[..queryParamSeparator]);
            headerData.QueryParameters = new PinnedByteSequence(url[(queryParamSeparator + 1)..]);
        }
        
        // Get the rest of the headers
        
        headerData.Headers = new PinnedByteSequence(headerSpan[(lineEnd + 2)..]);
        
        return headerData;
    }
    
    internal static H1HeaderData ExtractH1HeaderData(ReadOnlySpan<byte> headerSpan)
    {
        var headerData = new H1HeaderData();
        
        var lineEnd = headerSpan.IndexOf(Crlf);
        var firstHeader = headerSpan[..lineEnd];

        var firstSpace = firstHeader.IndexOf(Space);
        if (firstSpace == -1)
            throw new InvalidOperationException("Invalid request line");

        if (CachedH1Data.CachedHttpMethods.TryGetOrAdd(firstHeader[..firstSpace], out var httpMethod))
        {
            headerData.HttpMethod = httpMethod;
        }
        
        var secondSpaceRelative = firstHeader[(firstSpace + 1)..].IndexOf(Space);
        if (secondSpaceRelative == -1)
            throw new InvalidOperationException("Invalid request line");

        var secondSpace = firstSpace + secondSpaceRelative + 1;
        
        // REQUEST-TARGET slice: may include path + query (e.g., "/foo?bar=baz")
        var url = firstHeader[(firstSpace + 1)..secondSpace];

        var queryParamSeparator = url.IndexOf(Question);

        if (queryParamSeparator == -1)
        {
            if (CachedH1Data.CachedHttpMethods.TryGetOrAdd(url, out var route))
            {
                headerData.Route = route;
            }
        }
        else
        {
            if (CachedH1Data.CachedHttpMethods.TryGetOrAdd(url[..queryParamSeparator], out var route))
            {
                headerData.Route = route;
            }

            var querySpan = url[(queryParamSeparator + 1)..];
            var current = 0;


            while (current < querySpan.Length)
            {
                var separator = querySpan[current..].IndexOf(QuerySeparator); // (byte)'&'
                ReadOnlySpan<byte> pair;

                if (separator == -1)
                {
                    pair = querySpan[current..];
                    current = querySpan.Length;
                }
                else
                {
                    pair = querySpan.Slice(current, separator);
                    current += separator + 1;
                }

                var equalsIndex = pair.IndexOf(Equal);
                if (equalsIndex == -1)
                    break;

                headerData.QueryParameters!.TryAdd(CachedH1Data.CachedQueryKeys.GetOrAdd(pair[..equalsIndex]),
                    Encoding.UTF8.GetString(pair[(equalsIndex + 1)..]));
            }
            
            // Parse remaining headers
            
            var lineStart = 0;
            while (true)
            {
                lineStart += lineEnd + 2;

                lineEnd = headerSpan[lineStart..].IndexOf("\r\n"u8);
                if (lineEnd == 0)
                {
                    // All Headers read
                    break;
                }

                var header = headerSpan.Slice(lineStart, lineEnd);
                var colonIndex = header.IndexOf(Colon);

                if (colonIndex == -1)
                {
                    // Malformed header
                    continue;
                }

                var headerKey = header[..colonIndex];
                var headerValue = header[(colonIndex + 2)..];

                headerData.Headers!.TryAdd(CachedH1Data.CachedHeaderKeys.GetOrAdd(headerKey),
                    CachedH1Data.CachedHeaderValues.GetOrAdd(headerValue));
            }
        }
        
        return headerData;
    }
    
    // ===== Common tokens (kept as ReadOnlySpan<byte> for zero-allocation literals) =====

    private static ReadOnlySpan<byte> Crlf => "\r\n"u8;
    private static ReadOnlySpan<byte> CrlfCrlf => "\r\n\r\n"u8;

    // ASCII byte codes (documented for clarity)
    private const byte Space = 0x20;        // ' '
    private const byte Question = 0x3F;     // '?'
    private const byte QuerySeparator = 0x26; // '&'
    private const byte Equal = 0x3D;        // '='
    private const byte Colon = 0x3A;        // ':'
    private const byte SemiColon = 0x3B;    // ';'
}