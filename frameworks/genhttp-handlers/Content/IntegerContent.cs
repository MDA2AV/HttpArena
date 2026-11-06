using System.Globalization;

using GenHTTP.Api.Protocol;

namespace genhttp.Content;

/// <summary>
/// A number written as text/plain.
/// </summary>
public sealed class IntegerContent : PooledContent<IntegerContent>
{
    private long _value;

    private int _length;

    public override ulong? Length => (ulong)_length;

    public override ContentType? Type => ContentType.TextPlain;

    public static IntegerContent From(long value)
    {
        var content = Rent();

        content._value = value;

        Span<byte> scratch = stackalloc byte[24];
        value.TryFormat(scratch, out content._length, default, CultureInfo.InvariantCulture);

        return content;
    }

    public override ValueTask WriteAsync(IResponseSink sink)
    {
        var writer = sink.Writer;

        _value.TryFormat(writer.GetSpan(_length), out var written, default, CultureInfo.InvariantCulture);

        writer.Advance(written);

        return ValueTask.CompletedTask;
    }

}
