using System.Text.Json;

namespace genhttp.Content;

/// <summary>
/// Pre-encoded property names shared by the JSON writers.
/// </summary>
public static class JsonNames
{
    public static readonly JsonEncodedText Items = JsonEncodedText.Encode("items");
    public static readonly JsonEncodedText Count = JsonEncodedText.Encode("count");
    public static readonly JsonEncodedText Id = JsonEncodedText.Encode("id");
    public static readonly JsonEncodedText Name = JsonEncodedText.Encode("name");
    public static readonly JsonEncodedText Category = JsonEncodedText.Encode("category");
    public static readonly JsonEncodedText Price = JsonEncodedText.Encode("price");
    public static readonly JsonEncodedText Quantity = JsonEncodedText.Encode("quantity");
    public static readonly JsonEncodedText Active = JsonEncodedText.Encode("active");
    public static readonly JsonEncodedText Tags = JsonEncodedText.Encode("tags");
    public static readonly JsonEncodedText Rating = JsonEncodedText.Encode("rating");
    public static readonly JsonEncodedText Score = JsonEncodedText.Encode("score");
    public static readonly JsonEncodedText Total = JsonEncodedText.Encode("total");

    public static readonly JsonWriterOptions WriterOptions = new() { SkipValidation = true };
}
