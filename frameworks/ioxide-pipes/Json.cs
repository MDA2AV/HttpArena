using System.Buffers.Text;
using System.Text;
using System.Text.Json;

namespace IoxidePipes;

/// <summary>
/// The dataset behind <c>/json/{count}?m=N</c>, parsed once at startup into UTF-8 so serializing a
/// response is a walk over it rather than a re-encode. Every field is written per request from
/// this model - nothing about a response is precomputed, since <c>total</c> depends on the
/// multiplier the request carries.
/// </summary>
internal sealed class Dataset
{
    internal readonly struct Item(long id, byte[] name, byte[] category, long price, long quantity,
                                  bool active, byte[][] tags, long score, long ratingCount)
    {
        public readonly long Id = id;
        public readonly byte[] Name = name;
        public readonly byte[] Category = category;
        public readonly long Price = price;
        public readonly long Quantity = quantity;
        public readonly bool Active = active;
        public readonly byte[][] Tags = tags;
        public readonly long Score = score;
        public readonly long RatingCount = ratingCount;
    }

    public static readonly Dataset Empty = new([]);

    private readonly Item[] _items;

    private Dataset(Item[] items) => _items = items;

    public int Count => _items.Length;

    public static Dataset Load(string path)
    {
        try
        {
            using JsonDocument doc = JsonDocument.Parse(File.ReadAllBytes(path));
            JsonElement root = doc.RootElement;
            var items = new Item[root.GetArrayLength()];
            int i = 0;

            foreach (JsonElement element in root.EnumerateArray())
            {
                JsonElement rating = element.GetProperty("rating");
                JsonElement tagList = element.GetProperty("tags");
                var tags = new byte[tagList.GetArrayLength()][];
                int t = 0;
                foreach (JsonElement tag in tagList.EnumerateArray())
                {
                    tags[t++] = Encoding.UTF8.GetBytes(tag.GetString() ?? "");
                }

                items[i++] = new Item(
                    element.GetProperty("id").GetInt64(),
                    Encoding.UTF8.GetBytes(element.GetProperty("name").GetString() ?? ""),
                    Encoding.UTF8.GetBytes(element.GetProperty("category").GetString() ?? ""),
                    element.GetProperty("price").GetInt64(),
                    element.GetProperty("quantity").GetInt64(),
                    element.GetProperty("active").GetBoolean(),
                    tags,
                    rating.GetProperty("score").GetInt64(),
                    rating.GetProperty("count").GetInt64());
            }

            return new Dataset(items);
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"[ioxide-pipes] dataset load failed ({path}): {e.Message}");
            return Empty;
        }
    }

    /// <summary>
    /// Serialize the first <paramref name="count"/> items into <paramref name="body"/>, with each
    /// item's <c>total</c> scaled by <paramref name="multiplier"/>. Returns the bytes written.
    /// </summary>
    public int Write(Growable body, int count, long multiplier)
    {
        count = Math.Clamp(count, 0, _items.Length);
        body.Reset();
        body.Append("{\"items\":["u8);

        for (int i = 0; i < count; i++)
        {
            if (i > 0)
            {
                body.Append(","u8);
            }

            ref readonly Item item = ref _items[i];
            body.Append("{\"id\":"u8);
            body.Append(item.Id);
            body.Append(",\"name\":\""u8);
            body.Append(item.Name);
            body.Append("\",\"category\":\""u8);
            body.Append(item.Category);
            body.Append("\",\"price\":"u8);
            body.Append(item.Price);
            body.Append(",\"quantity\":"u8);
            body.Append(item.Quantity);
            body.Append(item.Active ? ",\"active\":true,\"tags\":["u8 : ",\"active\":false,\"tags\":["u8);

            for (int t = 0; t < item.Tags.Length; t++)
            {
                if (t > 0)
                {
                    body.Append(","u8);
                }
                body.Append("\""u8);
                body.Append(item.Tags[t]);
                body.Append("\""u8);
            }

            body.Append("],\"rating\":{\"score\":"u8);
            body.Append(item.Score);
            body.Append(",\"count\":"u8);
            body.Append(item.RatingCount);
            body.Append("},\"total\":"u8);
            body.Append(item.Price * item.Quantity * multiplier);
            body.Append("}"u8);
        }

        body.Append("],\"count\":"u8);
        body.Append(count);
        body.Append("}"u8);
        return body.Length;
    }
}

/// <summary>
/// A grow-once scratch buffer, one per connection: the JSON body has to exist before its
/// Content-Length can be written, and an echo of a chunked upload has to be decoded before its
/// length is known. Both settle at a size within a few requests and stop allocating.
/// </summary>
internal sealed class Growable
{
    private byte[] _buffer = new byte[16 * 1024];

    public int Length { get; private set; }

    public ReadOnlySpan<byte> Span => _buffer.AsSpan(0, Length);

    public void Reset() => Length = 0;

    public void Append(ReadOnlySpan<byte> bytes)
    {
        Ensure(Length + bytes.Length);
        bytes.CopyTo(_buffer.AsSpan(Length));
        Length += bytes.Length;
    }

    public void Append(long value)
    {
        Ensure(Length + 20);
        Utf8Formatter.TryFormat(value, _buffer.AsSpan(Length), out int written);
        Length += written;
    }

    private void Ensure(int needed)
    {
        if (_buffer.Length < needed)
        {
            Array.Resize(ref _buffer, Math.Max(needed, _buffer.Length * 2));
        }
    }
}
