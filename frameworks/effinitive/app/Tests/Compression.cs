using System.Text.Json;
using EffinitiveFramework.Core;

namespace effinitive.Tests;

public class CompressionEndpoint : NoRequestEndpointBase<byte[]>
{
    protected override string Method => "GET";
    protected override string Route => "/compression";

    // Pre-serialize JSON at startup, same as ASP.NET's TypedResults.Bytes() approach.
    // The compression middleware handles gzip per-request.
    private static readonly byte[] PreSerializedJson = BuildJson();

    private static byte[] BuildJson()
    {
        var path = "/data/dataset-large.json";
        if (!File.Exists(path))
        {
            throw new FileNotFoundException($"Required dataset file not found: {path}", path);
        }

        var fileBytes = File.ReadAllBytes(path);
        var items = JsonSerializer.Deserialize(fileBytes, AppJsonContext.Default.ListDatasetItem);
        if (items == null)
        {
            throw new InvalidOperationException("Failed to deserialize /data/dataset-large.json");
        }

        var processed = new List<ProcessedItem>(items.Count);
        foreach (var d in items)
        {
            processed.Add(new ProcessedItem
            {
                Id = d.Id, Name = d.Name, Category = d.Category,
                Price = d.Price, Quantity = d.Quantity, Active = d.Active,
                Tags = d.Tags, Rating = d.Rating,
                Total = Math.Round(d.Price * d.Quantity, 2)
            });
        }

        var dto = new ResponseDto<ProcessedItem>(processed, processed.Count);
        return JsonSerializer.SerializeToUtf8Bytes(dto, AppJsonContext.Default.ResponseDtoProcessedItem);
    }

    public override ValueTask<byte[]> HandleAsync(CancellationToken ct)
    {
        return ValueTask.FromResult(PreSerializedJson);
    }
}
