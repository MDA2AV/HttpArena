using System.Text.Json.Serialization;

public sealed record ResponseDto<T>(IReadOnlyList<T> Items, int Count);

public sealed class DbResponseItemDto
{
    public int Id { get; set; }
    public string Name { get; set; } = "";
    public string Category { get; set; } = "";
    public double Price { get; set; }
    public int Quantity { get; set; }
    public bool Active { get; set; }
    public List<string> Tags { get; set; } = [];
    public RatingInfo Rating { get; set; } = new();
}

sealed class DatasetItem
{
    public int Id { get; set; }
    public string Name { get; set; } = "";
    public string Category { get; set; } = "";
    public double Price { get; set; }
    public int Quantity { get; set; }
    public bool Active { get; set; }
    public List<string> Tags { get; set; } = [];
    public RatingInfo Rating { get; set; } = new();
}

public sealed class ProcessedItem
{
    public int Id { get; set; }
    public string Name { get; set; } = "";
    public string Category { get; set; } = "";
    public double Price { get; set; }
    public int Quantity { get; set; }
    public bool Active { get; set; }
    public List<string> Tags { get; set; } = null!;
    public RatingInfo Rating { get; set; } = null!;
    public double Total { get; set; }
}

public sealed class RatingInfo
{
    public double Score { get; set; }
    public int Count { get; set; }
}

[JsonSerializable(typeof(ResponseDto<ProcessedItem>))]
[JsonSerializable(typeof(ResponseDto<DbResponseItemDto>))]
[JsonSerializable(typeof(DbResponseItemDto))]
[JsonSerializable(typeof(ProcessedItem))]
[JsonSerializable(typeof(RatingInfo))]
[JsonSerializable(typeof(List<string>))]
[JsonSerializable(typeof(List<DatasetItem>))]
[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
partial class AppJsonContext : JsonSerializerContext { }
