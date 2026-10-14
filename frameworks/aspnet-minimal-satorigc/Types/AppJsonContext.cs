using System.Text.Json.Serialization;

namespace HttpArena.Types;

[JsonSerializable(typeof(ItemsResponse<ProcessedItem>))]
[JsonSerializable(typeof(ItemsResponse<Item>))]
[JsonSerializable(typeof(Item))]
[JsonSerializable(typeof(List<Item>))]
[JsonSerializable(typeof(ProcessedItem))]
[JsonSerializable(typeof(RatingInfo))]
[JsonSerializable(typeof(List<string>))]
[JsonSerializable(typeof(CrudItemInput))]
[JsonSerializable(typeof(CrudListResponse))]
[JsonSerializable(typeof(CrudWriteResponse))]
[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    PropertyNameCaseInsensitive = true,
    NumberHandling = JsonNumberHandling.AllowReadingFromString)]
public partial class AppJsonContext : JsonSerializerContext { }
