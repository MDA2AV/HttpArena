using System.Text.Json;
using System.Text.Json.Serialization;

public sealed class Rating
{
    [JsonPropertyName("score")] public long Score { get; set; }
    [JsonPropertyName("count")] public long Count { get; set; }
}

public sealed class DatasetItem
{
    [JsonPropertyName("id")]       public long   Id       { get; set; }
    [JsonPropertyName("name")]     public string Name     { get; set; } = "";
    [JsonPropertyName("category")] public string Category { get; set; } = "";
    [JsonPropertyName("price")]    public long   Price    { get; set; }
    [JsonPropertyName("quantity")] public long   Quantity { get; set; }
    [JsonPropertyName("active")]   public bool   Active   { get; set; }
    [JsonPropertyName("tags")]     public string[] Tags   { get; set; } = [];
    [JsonPropertyName("rating")]   public Rating Rating   { get; set; } = new();
}

public sealed class OutItem
{
    [JsonPropertyName("id")]       public long   Id       { get; set; }
    [JsonPropertyName("name")]     public string Name     { get; set; } = "";
    [JsonPropertyName("category")] public string Category { get; set; } = "";
    [JsonPropertyName("price")]    public long   Price    { get; set; }
    [JsonPropertyName("quantity")] public long   Quantity { get; set; }
    [JsonPropertyName("active")]   public bool   Active   { get; set; }
    [JsonPropertyName("tags")]     public string[] Tags   { get; set; } = [];
    [JsonPropertyName("rating")]   public Rating Rating   { get; set; } = new();
    [JsonPropertyName("total")]    public long   Total    { get; set; }
}

public sealed class OutList
{
    [JsonPropertyName("items")] public List<OutItem> Items { get; set; } = [];
    [JsonPropertyName("count")] public int Count { get; set; }
}

public sealed class DatasetService
{
    public DatasetItem[] Items { get; }

    public DatasetService()
    {
        var path = Environment.GetEnvironmentVariable("DATASET_PATH")
                   ?? "/data/dataset.json";
        try
        {
            Items = JsonSerializer.Deserialize<DatasetItem[]>(
                        File.ReadAllBytes(path)) ?? [];
        }
        catch
        {
            Items = [];
        }
    }
}