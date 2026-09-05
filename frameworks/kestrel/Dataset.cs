using System.Buffers;
using System.IO.Compression;
using System.Text.Json;

namespace KestrelArena;

/// <summary>
/// The dataset behind /json, parsed once at startup and serialized on every request.
/// </summary>
/// <remarks>
/// Deliberately no precomputed responses. The workload asks for the same handful of shapes
/// millions of times, so caching the finished bytes would turn the endpoint into a lookup table
/// and the profile would stop measuring anything the server does - which is what the board's
/// anti-cheat check exists to catch. The model is walked and serialized per request, the way the
/// other engine entries do it.
///
/// What is reused is only scratch: the buffers the serializer and the compressor write into are
/// per-thread and grow to their high-water mark, so steady state allocates the item array and
/// nothing else.
/// </remarks>
public sealed class Dataset
{
    private readonly List<Item>? _items;

    [ThreadStatic] private static ArrayBufferWriter<byte>? _json;
    [ThreadStatic] private static byte[]? _compressed;

    public Dataset()
    {
        var path = Environment.GetEnvironmentVariable("DATASET_PATH") ?? "/data/dataset.json";

        if (File.Exists(path))
        {
            _items = JsonSerializer.Deserialize(File.ReadAllText(path), AppJsonContext.Default.ListItem);
        }
    }

    public bool IsAvailable => _items is not null;

    /// <summary>
    /// Serializes the response for this count and multiplier, compressing it when the client said
    /// it would take one. Returns a span over per-thread scratch, valid until the next call on
    /// this thread - the caller writes it out before returning.
    /// </summary>
    public ReadOnlySpan<byte> Render(int count, int multiplier, bool wantsBrotli, bool wantsGzip, out string? encoding)
    {
        encoding = null;

        if (_items is null)
        {
            return default;
        }

        var source = _items;

        if (count > source.Count)
        {
            count = source.Count;
        }
        if (count < 0)
        {
            count = 0;
        }

        var items = new ProcessedItem[count];

        for (var i = 0; i < count; i++)
        {
            var item = source[i];

            items[i] = new ProcessedItem
            {
                Id = item.Id,
                Name = item.Name,
                Category = item.Category,
                Price = item.Price,
                Quantity = item.Quantity,
                Active = item.Active,
                Tags = item.Tags,
                Rating = item.Rating,
                Total = (long)item.Price * item.Quantity * multiplier
            };
        }

        var buffer = _json ??= new ArrayBufferWriter<byte>(16 * 1024);
        buffer.ResetWrittenCount();

        using (var writer = new Utf8JsonWriter(buffer))
        {
            JsonSerializer.Serialize(writer, new ItemsResponse<ProcessedItem>(items, count),
                                     AppJsonContext.Default.ItemsResponseProcessedItem);
        }

        var body = buffer.WrittenSpan;

        // Compressed only when asked for, never by default: a response that arrives compressed
        // without Accept-Encoding is what the anti-cheat check looks for.
        if (wantsBrotli)
        {
            encoding = "br";
            return Compress(body, brotli: true);
        }

        if (wantsGzip)
        {
            encoding = "gzip";
            return Compress(body, brotli: false);
        }

        return body;
    }

    // Quality 1: the profile measures a server compressing a response, not the ratio a slow
    // encoder can reach, and the cost of the default level would swamp everything else here.
    private static ReadOnlySpan<byte> Compress(ReadOnlySpan<byte> body, bool brotli)
    {
        var max = brotli
            ? BrotliEncoder.GetMaxCompressedLength(body.Length)
            : body.Length + (body.Length >> 2) + 64;

        var scratch = _compressed;

        if (scratch is null || scratch.Length < max)
        {
            _compressed = scratch = new byte[Math.Max(max, 16 * 1024)];
        }

        if (brotli)
        {
            BrotliEncoder.TryCompress(body, scratch, out var written, quality: 1, window: 22);
            return scratch.AsSpan(0, written);
        }

        using var output = new MemoryStream(scratch, 0, scratch.Length, writable: true);

        using (var gzip = new GZipStream(output, CompressionLevel.Fastest, leaveOpen: true))
        {
            gzip.Write(body);
        }

        return scratch.AsSpan(0, (int)output.Position);
    }
}
