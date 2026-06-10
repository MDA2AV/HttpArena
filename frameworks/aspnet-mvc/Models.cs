using System.Text.Json.Serialization;

sealed record ResponseDto<T>(IReadOnlyList<T> Items, int Count);

sealed class DbResponseItemDto
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

sealed class DatasetItem
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

sealed class ProcessedItem
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

sealed class RatingInfo
{
    public int Score { get; set; }
    public int Count { get; set; }
}

sealed class CrudListResponse
{
    public List<DbResponseItemDto> Items { get; set; } = [];
    public long Total { get; set; }
    public int Page { get; set; }
    public int Limit { get; set; }
}

sealed class CrudWriteResponse
{
    public int Id { get; set; }
    public string? Name { get; set; }
    public string? Category { get; set; }
    public int Price { get; set; }
    public int Quantity { get; set; }
}

public sealed record Fortune(int Id, string Message);

public record CrudItemInput(int Id, string? Name, string? Category, int Price, int Quantity);

[JsonSerializable(typeof(ResponseDto<ProcessedItem>))]
[JsonSerializable(typeof(ResponseDto<DbResponseItemDto>))]
[JsonSerializable(typeof(DbResponseItemDto))]
[JsonSerializable(typeof(ProcessedItem))]
[JsonSerializable(typeof(RatingInfo))]
[JsonSerializable(typeof(List<string>))]
[JsonSerializable(typeof(CrudListResponse))]
[JsonSerializable(typeof(CrudWriteResponse))]
[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
partial class AppJsonContext : JsonSerializerContext;
