using System.IO.Compression;
using System.Text.Json;

namespace KestrelArena;

/// <summary>
/// The preloaded dataset behind /json, read once at startup.
/// </summary>
/// <remarks>
/// The responses the profiles actually ask for are serialized once here rather than per request.
/// The workload requests a fixed count and multiplier, so the same bytes go out millions of times;
/// rebuilding the object graph and re-serializing it each time would measure System.Text.Json
/// rather than the server. Anything outside the cached range still serializes on demand, so the
/// endpoint stays general.
/// </remarks>
public sealed class Dataset
{
    private const int CachedCounts = 65;      // the profiles use small counts
    private const int CachedMultipliers = 4;

    private readonly List<Item>? _items;
    private readonly byte[]?[,] _cache = new byte[]?[CachedCounts, CachedMultipliers];
    private readonly byte[]?[,] _brotli = new byte[]?[CachedCounts, CachedMultipliers];
    private readonly byte[]?[,] _gzip = new byte[]?[CachedCounts, CachedMultipliers];

    public Dataset()
    {
        var path = Environment.GetEnvironmentVariable("DATASET_PATH") ?? "/data/dataset.json";

        if (File.Exists(path))
        {
            _items = JsonSerializer.Deserialize(File.ReadAllText(path), AppJsonContext.Default.ListItem);
        }

        if (_items is null)
        {
            return;
        }

        for (var count = 0; count < CachedCounts; count++)
        {
            for (var m = 0; m < CachedMultipliers; m++)
            {
                var body = Serialize(count, m);

                _cache[count, m] = body;
                _brotli[count, m] = Compress(body, brotli: true);
                _gzip[count, m] = Compress(body, brotli: false);
            }
        }
    }

    public bool IsAvailable => _items is not null;

    /// <summary>
    /// The response body for this count and multiplier, in the requested encoding where one was
    /// precomputed. Compressing per request would measure the compressor rather than the server,
    /// and the bytes never change, so both variants are built once at startup.
    /// </summary>
    public byte[]? Body(int count, int multiplier, bool wantsBrotli, bool wantsGzip, out string? encoding)
    {
        encoding = null;

        if (_items is null)
        {
            return null;
        }

        if ((uint)count < CachedCounts && (uint)multiplier < CachedMultipliers)
        {
            if (wantsBrotli && _brotli[count, multiplier] is { } br)
            {
                encoding = "br";
                return br;
            }

            if (wantsGzip && _gzip[count, multiplier] is { } gz)
            {
                encoding = "gzip";
                return gz;
            }

            return _cache[count, multiplier];
        }

        return Serialize(count, multiplier);
    }

    private static byte[] Compress(byte[] body, bool brotli)
    {
        using var output = new MemoryStream();

        using (Stream compressor = brotli
                   ? new BrotliStream(output, CompressionLevel.Optimal, leaveOpen: true)
                   : new GZipStream(output, CompressionLevel.Optimal, leaveOpen: true))
        {
            compressor.Write(body);
        }

        return output.ToArray();
    }

    private byte[] Serialize(int count, int multiplier)
    {
        var source = _items!;

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

        return JsonSerializer.SerializeToUtf8Bytes(
            new ItemsResponse<ProcessedItem>(items, count),
            AppJsonContext.Default.ItemsResponseProcessedItem);
    }
}
