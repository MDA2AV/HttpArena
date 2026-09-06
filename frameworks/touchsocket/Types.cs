using System.Text.Json.Serialization;

namespace TouchSocketArena;

/// <summary>An item as stored in the dataset file.</summary>
public sealed class Item
{
    public int Id { get; set; }
    public string Name { get; set; } = "";
    public string Category { get; set; } = "";
    public int Price { get; set; }
    public int Quantity { get; set; }
    public bool Active { get; set; }
    public List<string> Tags { get; set; } = [];
    public RatingInfo Rating { get; set; } = new();
}

/// <summary>A dataset item with the computed total the /json workload asks for.</summary>
public sealed class ProcessedItem
{
    public int Id { get; set; }
    public string Name { get; set; } = "";
    public string Category { get; set; } = "";
    public int Price { get; set; }
    public int Quantity { get; set; }
    public bool Active { get; set; }
    public List<string> Tags { get; set; } = [];
    public RatingInfo Rating { get; set; } = new();
    public long Total { get; set; }
}

public sealed class RatingInfo
{
    public int Score { get; set; }
    public int Count { get; set; }
}

public sealed record ItemsResponse<T>(IReadOnlyList<T> Items, int Count);

// Source-generated so the JSON path costs no reflection at runtime, and the same
// camelCase shape the other entries answer with.
[JsonSerializable(typeof(ItemsResponse<ProcessedItem>))]
[JsonSerializable(typeof(List<Item>))]
[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    PropertyNameCaseInsensitive = true,
    NumberHandling = JsonNumberHandling.AllowReadingFromString)]
public partial class AppJsonContext : JsonSerializerContext { }
