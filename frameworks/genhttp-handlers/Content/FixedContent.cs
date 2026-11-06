using System.Buffers;

using GenHTTP.Api.Protocol;

namespace genhttp.Content;

/// <summary>
/// Immutable content that can be shared by all responses.
/// </summary>
public sealed class FixedContent(ReadOnlyMemory<byte> data, ContentType type) : IResponseContent
{

    public ulong? Length => (ulong)data.Length;

    public ContentType? Type => type;

    public ReadOnlyMemory<byte>? Encoding => null;

    public ValueTask<ulong?> CalculateChecksumAsync() => new((ulong?)null);

    public ValueTask WriteAsync(IResponseSink sink)
    {
        sink.Writer.Write(data.Span);
        return ValueTask.CompletedTask;
    }

}
