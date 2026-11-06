using System.Buffers;
using System.Text.Json;

using GenHTTP.Api.Protocol;

namespace genhttp.Content;

/// <summary>
/// JSON that has to be produced asynchronously (e.g. from a database reader)
/// and is therefore buffered before it is sent.
/// </summary>
/// <remarks>
/// Buffer and writer belong to the pooled instance, so they are reused
/// across requests.
/// </remarks>
public sealed class BufferedJsonContent : PooledContent<BufferedJsonContent>
{
    private readonly ArrayBufferWriter<byte> _buffer = new(16 * 1024);

    private readonly Utf8JsonWriter _writer;

    public BufferedJsonContent()
    {
        _writer = new Utf8JsonWriter(_buffer, JsonNames.WriterOptions);
    }

    public override ulong? Length => (ulong)_buffer.WrittenCount;

    public override ContentType? Type => ContentType.ApplicationJson;

    /// <summary>
    /// The writer to fill. Flush it before responding.
    /// </summary>
    public Utf8JsonWriter Writer => _writer;

    public override ValueTask WriteAsync(IResponseSink sink)
    {
        var data = _buffer.WrittenSpan;

        var writer = sink.Writer;

        data.CopyTo(writer.GetSpan(data.Length));

        writer.Advance(data.Length);

        return ValueTask.CompletedTask;
    }

    protected override void Clear()
    {
        _writer.Reset();
        _buffer.ResetWrittenCount();
    }

}
