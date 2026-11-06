using System.Globalization;
using System.Runtime.CompilerServices;

using GenHTTP.Api.Protocol;

namespace genhttp.Handlers;

/// <summary>
/// Reads numbers from the raw bytes of the request, without
/// materializing strings.
/// </summary>
public static class Parameters
{

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static bool TryParse(ReadOnlySpan<byte> value, out int result)
        => int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out result);

    /// <summary>
    /// Reads the given query parameter as an integer.
    /// </summary>
    /// <returns>The value, or the fallback if it is missing or invalid</returns>
    public static int Query(IRequestQuery query, ReadOnlySpan<byte> key, int fallback)
    {
        for (var i = 0; i < query.Count; i++)
        {
            var entry = query.GetMemoryEntry(i);

            if (entry.Key.Span.SequenceEqual(key))
            {
                return TryParse(entry.Value.Span, out var value) ? value : fallback;
            }
        }

        return fallback;
    }

    /// <summary>
    /// Reads the current path segment as an integer.
    /// </summary>
    public static bool TryPath(IRequestTarget target, out int value)
    {
        var current = target.Current;

        if (current is not null)
        {
            return TryParse(current.Value.Bytes.Span, out value);
        }

        value = 0;
        return false;
    }

}
