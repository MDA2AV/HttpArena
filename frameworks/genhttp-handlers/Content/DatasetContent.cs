using System.Buffers;
using System.Text.Json;

using GenHTTP.Api.Protocol;

using static genhttp.Content.JsonNames;

namespace genhttp.Content;

/// <summary>
/// Serializes the first items of the dataset with their computed totals
/// directly into the response sink.
/// </summary>
public sealed class DatasetContent : PooledContent<DatasetContent>
{
    // writing is synchronous, so a writer per thread can be reused safely
    [ThreadStatic]
    private static Utf8JsonWriter? _writer;

    private DatasetItem[] _items = [];

    private int _count;

    private long _multiplier;

    public override ulong? Length => null;

    public override ContentType? Type => ContentType.ApplicationJson;

    public static DatasetContent From(DatasetItem[] items, int count, long multiplier)
    {
        var content = Rent();

        content._items = items;
        content._count = count;
        content._multiplier = multiplier;

        return content;
    }

    public override ValueTask WriteAsync(IResponseSink sink)
    {
        var writer = Acquire(sink.Writer);

        try
        {
            var items = _items;
            var count = _count;
            var m = _multiplier;

            writer.WriteStartObject();
            writer.WriteStartArray(Items);

            for (var i = 0; i < count; i++)
            {
                var item = items[i];

                writer.WriteStartObject();

                writer.WriteNumber(Id, item.Id);
                writer.WriteString(Name, item.Name);
                writer.WriteString(Category, item.Category);
                writer.WriteNumber(Price, item.Price);
                writer.WriteNumber(Quantity, item.Quantity);
                writer.WriteBoolean(Active, item.Active);

                writer.WriteStartArray(Tags);

                var tags = item.Tags;

                for (var t = 0; t < tags.Length; t++)
                {
                    writer.WriteStringValue(tags[t]);
                }

                writer.WriteEndArray();

                writer.WriteStartObject(Rating);
                writer.WriteNumber(Score, item.Rating.Score);
                writer.WriteNumber(Count, item.Rating.Count);
                writer.WriteEndObject();

                writer.WriteNumber(Total, (long)item.Price * item.Quantity * m);

                writer.WriteEndObject();
            }

            writer.WriteEndArray();
            writer.WriteNumber(Count, count);
            writer.WriteEndObject();

            writer.Flush();
        }
        finally
        {
            writer.Reset();
        }

        return ValueTask.CompletedTask;
    }

    private static Utf8JsonWriter Acquire(IBufferWriter<byte> output)
    {
        var writer = _writer;

        if (writer == null)
        {
            return _writer = new Utf8JsonWriter(output, WriterOptions);
        }

        writer.Reset(output);
        return writer;
    }

    protected override void Clear() => _items = [];

}
