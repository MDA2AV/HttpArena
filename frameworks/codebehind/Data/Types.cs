using System.Text.Json.Serialization;

namespace HttpArena.Data;

/// <summary>
/// An item as stored in the dataset file and the Postgres `items` table.
/// </summary>
public sealed class Item
{
    public int Id { get; init; }
    public string Name { get; init; } = "";
    public string Category { get; init; } = "";
    public int Price { get; init; }
    public int Quantity { get; init; }
    public bool Active { get; init; }
    public List<string> Tags { get; init; } = [];
    public RatingInfo Rating { get; init; } = new();
}

/// <summary>
/// A dataset item with its total computed for the /json endpoint.
/// </summary>
public sealed class ProcessedItem
{
    public int Id { get; init; }
    public string Name { get; init; } = "";
    public string Category { get; init; } = "";
    public int Price { get; init; }
    public int Quantity { get; init; }
    public bool Active { get; init; }
    public List<string> Tags { get; init; } = [];
    public RatingInfo Rating { get; init; } = new();
    public long Total { get; init; }
}

public sealed class RatingInfo
{
    public int Score { get; init; }
    public int Count { get; init; }
}

public sealed record ItemsResponse<T>(IReadOnlyList<T> Items, int Count);

public sealed record Fortune(int Id, string Message);

[JsonSerializable(typeof(List<Item>))]
[JsonSerializable(typeof(List<string>))]
[JsonSerializable(typeof(ItemsResponse<Item>))]
[JsonSerializable(typeof(ItemsResponse<ProcessedItem>))]
[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true)]
public sealed partial class AppJsonContext : JsonSerializerContext;
