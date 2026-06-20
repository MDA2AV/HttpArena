using System.Text;
using System.Text.Json;

namespace MonoxideArena;

/// <summary>One dataset item, parsed to model fields at startup and serialized field-by-field per
/// request (no precomputed response fragments). String values are clean ASCII in the bench dataset.</summary>
internal readonly struct Item(long id, byte[] name, byte[] category, long price, long quantity,
                              bool active, byte[][] tags, long score, long ratingCount)
{
    public readonly long Id = id, Price = price, Quantity = quantity, Score = score, RatingCount = ratingCount;
    public readonly bool Active = active;
    public readonly byte[] Name = name, Category = category;
    public readonly byte[][] Tags = tags;
}

/// <summary>Read-only items for the json profile, shared across reactor threads after load.</summary>
internal sealed class Dataset
{
    public readonly Item[] Items;
    public int Count => Items.Length;
    public static readonly Dataset Empty = new(Array.Empty<Item>());

    private Dataset(Item[] items) => Items = items;

    public static Dataset Load(string path)
    {
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllBytes(path));
            JsonElement root = doc.RootElement;
            var items = new Item[root.GetArrayLength()];
            int i = 0;
            foreach (JsonElement e in root.EnumerateArray())
            {
                JsonElement rating = e.GetProperty("rating");
                JsonElement tagsEl = e.GetProperty("tags");
                var tags = new byte[tagsEl.GetArrayLength()][];
                int t = 0;
                foreach (JsonElement tag in tagsEl.EnumerateArray())
                    tags[t++] = Encoding.UTF8.GetBytes(tag.GetString() ?? "");
                items[i++] = new Item(
                    e.GetProperty("id").GetInt64(),
                    Encoding.UTF8.GetBytes(e.GetProperty("name").GetString() ?? ""),
                    Encoding.UTF8.GetBytes(e.GetProperty("category").GetString() ?? ""),
                    e.GetProperty("price").GetInt64(),
                    e.GetProperty("quantity").GetInt64(),
                    e.GetProperty("active").GetBoolean(),
                    tags,
                    rating.GetProperty("score").GetInt64(),
                    rating.GetProperty("count").GetInt64());
            }
            return new Dataset(items);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[monoxide] dataset load failed ({path}): {ex.Message}");
            return Empty;
        }
    }
}
