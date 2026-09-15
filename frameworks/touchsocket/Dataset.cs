using System.Buffers;
using System.IO.Compression;
using System.Text.Json;

namespace TouchSocketArena;

/// <summary>
/// The dataset behind /json, parsed once at startup and serialized on every request.
/// </summary>
/// <remarks>
/// No precomputed responses: the workload asks for the same few shapes millions of times, so
/// caching the finished bytes would turn the endpoint into a lookup table and stop measuring the
/// server at all. Only scratch is reused - the serializer's buffer and the compressor's, both per
/// thread and grown to their high-water mark.
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

    public int Count => _items?.Count ?? 0;

    /// <summary>
    /// Serializes the response for this count and multiplier, compressing it only when the client
    /// said it would take one. Watson's Send takes a byte[], so the result is copied out of the
    /// per-thread scratch rather than handed over as a span.
    /// </summary>
    public byte[]? Render(int count, int multiplier, bool wantsBrotli, bool wantsGzip, out string? encoding)
    {
        encoding = null;

        if (_items is null)
        {
            return null;
        }

        var source = _items;

        if (count > source.Count) count = source.Count;
        if (count < 0) count = 0;

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

        var buffer = _json ??= new ArrayBufferWriter<byte>(32 * 1024);
        buffer.ResetWrittenCount();

        using (var writer = new Utf8JsonWriter(buffer))
        {
            JsonSerializer.Serialize(writer, new ItemsResponse<ProcessedItem>(items, count),
                                     AppJsonContext.Default.ItemsResponseProcessedItem);
        }

        var body = buffer.WrittenSpan;

        // Never compressed unless asked for: a response that arrives encoded without
        // Accept-Encoding is exactly what the board's anti-cheat check looks for.
        if (wantsBrotli)
        {
            encoding = "br";
            return Compress(body, brotli: true).ToArray();
        }

        if (wantsGzip)
        {
            encoding = "gzip";
            return Compress(body, brotli: false).ToArray();
        }

        return body.ToArray();
    }

    // Quality 1: the profile measures a server compressing a response, not the ratio a slow
    // encoder can reach.
    private static ReadOnlySpan<byte> Compress(ReadOnlySpan<byte> body, bool brotli)
    {
        var max = brotli
            ? BrotliEncoder.GetMaxCompressedLength(body.Length)
            : body.Length + (body.Length >> 2) + 64;

        var scratch = _compressed;

        if (scratch is null || scratch.Length < max)
        {
            _compressed = scratch = new byte[Math.Max(max, 32 * 1024)];
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
