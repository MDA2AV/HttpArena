using System.Text.Json;

namespace HttpArena.Data;

/// <summary>
/// The item dataset behind the /json endpoint, read once at startup.
/// </summary>
public sealed class DatasetService
{
    private readonly List<Item> _items;

    public DatasetService(IConfiguration configuration)
    {
        var path = configuration["DATASET_PATH"] ?? "/data/dataset.json";

        _items = File.Exists(path)
            ? JsonSerializer.Deserialize(File.ReadAllText(path), AppJsonContext.Default.ListItem) ?? []
            : [];
    }

    public bool IsAvailable => _items.Count > 0;

    /// <summary>
    /// The first <paramref name="count"/> items, each with its total computed
    /// as price * quantity * <paramref name="multiplier"/>.
    /// </summary>
    public ItemsResponse<ProcessedItem> GetItems(int count, int multiplier)
    {
        count = Math.Clamp(count, 0, _items.Count);

        var items = new ProcessedItem[count];

        for (var i = 0; i < count; i++)
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
                Total = (long)item.Price * item.Quantity * multiplier
            };
        }

        return new ItemsResponse<ProcessedItem>(items, count);
    }
}
