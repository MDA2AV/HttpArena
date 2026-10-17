using System.Text.Json;

using HttpArena.Types;

namespace HttpArena.Services;

/// <summary>
/// Serves the preloaded JSON dataset for the /json workload.
/// </summary>
public sealed class DatasetService
{
    private readonly List<Item>? _items;

    public DatasetService()
    {
        var path = Environment.GetEnvironmentVariable("DATASET_PATH") ?? "/data/dataset.json";
        if (File.Exists(path))
        {
            _items = JsonSerializer.Deserialize(File.ReadAllText(path), AppJsonContext.Default.ListItem);
        }
    }

    public bool IsAvailable => _items is not null;

    /// <summary>
    /// Returns the first <paramref name="count"/> dataset items with their
    /// total computed as price * quantity * <paramref name="multiplier"/>,
    /// or null when no dataset is loaded.
    /// </summary>
    public ItemsResponse<ProcessedItem>? GetItems(int count, int multiplier)
    {
        if (_items is null) return null;

        if (count > _items.Count) count = _items.Count;
        if (count < 0) count = 0;

        var items = new ProcessedItem[count];

        for (int i = 0; i < count; i++)
        {
            var item = _items[i];
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
                Total = item.Price * item.Quantity * multiplier
            };
        }

        return new ItemsResponse<ProcessedItem>(items, count);
    }
}
