using System.Text.Json;
using EffinitiveFramework.Core;
using EffinitiveFramework.Core.Http;

namespace effinitive.Tests;

// Returns byte[] so SerializeResponse short-circuits into the pre-serialized path,
// bypassing reflection-based JsonSerializerOptions entirely.
public class JsonEndpoint : NoRequestEndpointBase<byte[]>
{
    protected override string Method => "GET";
    protected override string Route => "/json/{count}";

    private static readonly DatasetItem[] AllItems = LoadItems();

    private static DatasetItem[] LoadItems()
    {
        var path = Environment.GetEnvironmentVariable("DATASET_PATH") ?? "/data/dataset.json";
        if (!File.Exists(path))
            throw new FileNotFoundException($"Required dataset file not found: {path}", path);

        var fileBytes = File.ReadAllBytes(path);
        var items = JsonSerializer.Deserialize(fileBytes, AppJsonContext.Default.ListDatasetItem);
        if (items == null)
            throw new InvalidOperationException($"Failed to deserialize dataset file: {path}");
        return [.. items];
    }

    public override ValueTask<byte[]> HandleAsync(CancellationToken ct)
    {
        var query = HttpContext?.Query ?? QueryCollection.Empty;
        int count = int.TryParse(HttpContext?.RouteValues?["count"]?.ToString(), out var c) ? c : AllItems.Length;
        double m = query.GetDouble("m", 1.0);

        int take = Math.Min(count, AllItems.Length);
        var processed = new ProcessedItem[take];
        for (int i = 0; i < take; i++)
        {
            var d = AllItems[i];
            processed[i] = new ProcessedItem
            {
                Id = d.Id, Name = d.Name, Category = d.Category,
                Price = d.Price, Quantity = d.Quantity, Active = d.Active,
                Tags = d.Tags, Rating = d.Rating,
                Total = Math.Round(d.Price * d.Quantity * m, 2)
            };
        }

        var dto = new ResponseDto<ProcessedItem>(processed, take);
        return ValueTask.FromResult(
            JsonSerializer.SerializeToUtf8Bytes(dto, AppJsonContext.Default.ResponseDtoProcessedItem));
    }
}
