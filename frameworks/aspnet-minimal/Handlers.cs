using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.AspNetCore.Http.HttpResults;


[JsonSerializable(typeof(ResponseDto))]
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

    public static async Task<IResult> Upload(HttpRequest req)
    {
        long size = 0;
        var buffer = new byte[65536];
        int read;
        while ((read = await req.Body.ReadAsync(buffer)) > 0)
        {
            size += read;
        }
        return Results.Text(size.ToString());
    }

    public static Results<JsonHttpResult<ResponseDto>, ProblemHttpResult> Json()
    {
        if (AppData.DatasetItems == null)
            return TypedResults.Problem("Dataset not loaded");

        var items = new List<ProcessedItem>(AppData.DatasetItems.Count);
        foreach (var item in AppData.DatasetItems)
        {
            items.Add(new ProcessedItem
            {
                Id = item.Id,
                Name = item.Name,
                Category = item.Category,
                Price = item.Price,
                Quantity = item.Quantity,
                Active = item.Active,
                Tags = item.Tags,
                Rating = item.Rating,
                Total = Math.Round(item.Price * item.Quantity, 2)
            });
        }

        return TypedResults.Json(new ResponseDto(items, AppData.DatasetItems.Count), AppJsonContext.Default);
    }

    public static IResult Compression()
    {
        if (AppData.LargeJsonResponse == null)
        {
            return Results.StatusCode(500);
        }

        return Results.Bytes(AppData.LargeJsonResponse, "application/json");
    }

    public static IResult Database(HttpRequest req)
    {
        if (AppData.DbConnection == null)
            return Results.Problem("DB not available");

        double min = 10, max = 50;
        if (req.Query.ContainsKey("min") && double.TryParse(req.Query["min"], out double pmin))
            min = pmin;
        if (req.Query.ContainsKey("max") && double.TryParse(req.Query["max"], out double pmax))
            max = pmax;

        using var cmd = AppData.DbConnection.CreateCommand();
        cmd.CommandText = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN @min AND @max LIMIT 50";
        cmd.Parameters.AddWithValue("@min", min);
        cmd.Parameters.AddWithValue("@max", max);
        using var reader = cmd.ExecuteReader();

        var items = new List<object>();
        while (reader.Read())
        {
            items.Add(new
            {
                id = reader.GetInt32(0),
                name = reader.GetString(1),
                category = reader.GetString(2),
                price = reader.GetDouble(3),
                quantity = reader.GetInt32(4),
                active = reader.GetInt32(5) == 1,
                tags = JsonSerializer.Deserialize<List<string>>(reader.GetString(6)),
                rating = new { score = reader.GetDouble(7), count = reader.GetInt32(8) },
            });
        }
        return Results.Json(new { items, count = items.Count });
    }

    public static async Task<IResult> AsyncDatabase(HttpRequest req)
    {
        if (AppData.PgDataSource == null)
            return Results.Json(new { items = Array.Empty<object>(), count = 0 });

        double min = 10, max = 50;
        if (req.Query.ContainsKey("min") && double.TryParse(req.Query["min"], out double pmin))
            min = pmin;
        if (req.Query.ContainsKey("max") && double.TryParse(req.Query["max"], out double pmax))
            max = pmax;

        await using var cmd = AppData.PgDataSource.CreateCommand(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT 50");
        cmd.Parameters.AddWithValue(min);
        cmd.Parameters.AddWithValue(max);
        await using var reader = await cmd.ExecuteReaderAsync();

        var items = new List<object>();
        while (await reader.ReadAsync())
        {
            items.Add(new
            {
                id = reader.GetInt32(0),
                name = reader.GetString(1),
                category = reader.GetString(2),
                price = reader.GetDouble(3),
                quantity = reader.GetInt32(4),
                active = reader.GetBoolean(5),
                tags = JsonSerializer.Deserialize<List<string>>(reader.GetString(6)),
                rating = new { score = reader.GetDouble(7), count = reader.GetInt32(8) },
            });
        }
        return Results.Json(new { items, count = items.Count });
    }

}
