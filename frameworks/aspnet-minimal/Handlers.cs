using System.Text.Json;
using System.Buffers;
using System.Text.Json.Serialization;
using Microsoft.AspNetCore.Http.HttpResults;


[JsonSerializable(typeof(ResponseDto<ProcessedItem>))]
[JsonSerializable(typeof(ResponseDto<DbResponseItemDto>))]
[JsonSerializable(typeof(DbResponseItemDto))]
[JsonSerializable(typeof(ProcessedItem))]
[JsonSerializable(typeof(RatingInfo))]
[JsonSerializable(typeof(List<string>))]
[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
partial class AppJsonContext : JsonSerializerContext { }

static class Handlers
{
    public static int Sum(int a, int b) => a + b;

    public static async ValueTask<int> SumBody(int a, int b, HttpRequest req)
    {
        using var reader = new StreamReader(req.Body);
        return a + b + int.Parse(await reader.ReadToEndAsync());
    }

    public static string Text() => "ok";

    public static async ValueTask<string> Upload(HttpRequest req)
    {
        long size = 0;
        var buffer = ArrayPool<byte>.Shared.Rent(65536);
        try
        {
            int read;
            while ((read = await req.Body.ReadAsync(buffer.AsMemory(0, buffer.Length))) > 0)
            {
                size += read;
            }
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
        }

        return size.ToString();
    }

    public static Results<JsonHttpResult<ResponseDto<ProcessedItem>>, ProblemHttpResult> Json(int count, HttpRequest req)
    {
        var source = AppData.DatasetItems;
        if (source == null)
            return TypedResults.Problem("Dataset not loaded");

        if (count > source.Count) count = source.Count;
        if (count < 0) count = 0;

        int m = 1;
        if (req.Query.TryGetValue("m", out var mVal) && int.TryParse(mVal, out var pm)) m = pm;

        var items = new ProcessedItem[count];

        for (int i = 0; i < count; i++)
        {
            var item = source[i];
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
                Total = item.Price * item.Quantity * m
            };
        }

        return TypedResults.Json(new ResponseDto<ProcessedItem>(items, count), AppJsonContext.Default.ResponseDtoProcessedItem);
    }

    public static async Task<Results<JsonHttpResult<ResponseDto<DbResponseItemDto>>, ProblemHttpResult>> AsyncDatabase(HttpRequest req)
    {
        if (AppData.PgDataSource == null)
            return TypedResults.Problem("DB not available");

        // Query Parsing
        double min = 10, max = 50;
        int limit = 50;
        var query = req.Query;
        if (query.TryGetValue("min", out var minVal) && double.TryParse(minVal, out var pmin)) min = pmin;
        if (query.TryGetValue("max", out var maxVal) && double.TryParse(maxVal, out var pmax)) max = pmax;
        if (query.TryGetValue("limit", out var limVal) && int.TryParse(limVal, out var plim)) limit = Math.Clamp(plim, 1, 50);

        await using var cmd = AppData.PgDataSource.CreateCommand(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3");
        
        cmd.Parameters.AddWithValue(min);
        cmd.Parameters.AddWithValue(max);
        cmd.Parameters.AddWithValue(limit);

        await using var reader = await cmd.ExecuteReaderAsync();

        var items = new List<DbResponseItemDto>(limit);

        while (await reader.ReadAsync())
        {
            items.Add(new DbResponseItemDto
            {
                Id = reader.GetInt32(0),
                Name = reader.GetString(1),
                Category = reader.GetString(2),
                Price = (int)reader.GetDouble(3),
                Quantity = reader.GetInt32(4),
                Active = reader.GetBoolean(5),
                Tags = JsonSerializer.Deserialize(reader.GetString(6), AppJsonContext.Default.ListString)!,
                Rating = new RatingInfo { Score = (int)reader.GetDouble(7), Count = reader.GetInt32(8) }
            });
        }

        return TypedResults.Json(new ResponseDto<DbResponseItemDto>(items, items.Count), AppJsonContext.Default.ResponseDtoDbResponseItemDto);
    }
}