using GenHTTP.Api.Protocol;

namespace genhttp.Content;

/// <summary>
/// Writes the body of the request back to the client.
/// </summary>
/// <remarks>
/// The memory usually points into the read buffer of the connection, which the
/// engine keeps until the response has been written.
/// </remarks>
public sealed class EchoContent : PooledContent<EchoContent>
{
    private ReadOnlyMemory<byte> _data;

    public override ulong? Length => (ulong)_data.Length;

    public override ContentType? Type => ContentType.ApplicationOctetStream;

    public static EchoContent From(ReadOnlyMemory<byte> data)
    {
        var content = Rent();
        content._data = data;
        return content;
    }

    public override ValueTask WriteAsync(IResponseSink sink)
    {
        if (!_data.IsEmpty)
        {
            var writer = sink.Writer;

            _data.Span.CopyTo(writer.GetSpan(_data.Length));

            writer.Advance(_data.Length);
        }

        return ValueTask.CompletedTask;
    }

    protected override void Clear() => _data = default;

}
