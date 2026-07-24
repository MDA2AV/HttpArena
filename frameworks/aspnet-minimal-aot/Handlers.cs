using System.Buffers;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.Data.Sqlite;
using Npgsql;


[JsonSerializable(typeof(ResponseDto))]
[JsonSerializable(typeof(DbResponseDto))]
[JsonSerializable(typeof(DbItemDto))]
[JsonSerializable(typeof(List<DatasetItem>))]
[JsonSerializable(typeof(ProcessedItem))]
[JsonSerializable(typeof(RatingInfo))]
[JsonSerializable(typeof(List<string>))]
[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
partial class AppJsonContext : JsonSerializerContext { }

static class Handlers
{
    // Returning `string` makes ASP.NET minimal APIs set Content-Type to
    // text/plain automatically. Returning `int` defaults to JSON and
    // serializes the bare number — which violates the baseline contract.
    public static string Sum(int a, int b) => (a + b).ToString();

    public static async ValueTask<string> SumBody(int a, int b, HttpRequest req)
    {
        using var reader = new StreamReader(req.Body);
        return (a + b + int.Parse(await reader.ReadToEndAsync())).ToString();
    }

    public static string Text() => "ok";

    public static async Task<IResult> Upload(HttpRequest req)
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

        return Results.Text(size.ToString());
    }

    public static Results<JsonHttpResult<ResponseDto>, ProblemHttpResult> Json(int count, HttpRequest req)
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

        return TypedResults.Json(new ResponseDto(items, count), AppJsonContext.Default.ResponseDto);
    }

    public static Results<JsonHttpResult<DbResponseDto>, ProblemHttpResult> Database(HttpRequest req)
    {
        if (AppData.DbConnection == null)
            return TypedResults.Problem("DB not available");

        ReadPriceRange(req, out var min, out var max);

        using var cmd = AppData.DbConnection.CreateCommand();
        cmd.CommandText = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN @min AND @max LIMIT 50";
        cmd.Parameters.AddWithValue("@min", min);
        cmd.Parameters.AddWithValue("@max", max);
        using var reader = cmd.ExecuteReader();

        var items = new List<DbItemDto>(50);
        while (reader.Read())
        {
            items.Add(ReadSqliteItem(reader));
        }

        return TypedResults.Json(new DbResponseDto(items, items.Count), AppJsonContext.Default.DbResponseDto);
    }

    public static async Task<JsonHttpResult<DbResponseDto>> AsyncDatabase(HttpRequest req)
    {
        if (AppData.PgDataSource == null)
            return TypedResults.Json(new DbResponseDto([], 0), AppJsonContext.Default.DbResponseDto);

        ReadPriceRange(req, out var min, out var max);

        int limit = 50;
        if (req.Query.TryGetValue("limit", out var limVal) && int.TryParse(limVal, out var plim))
            limit = Math.Clamp(plim, 1, 50);

        await using var cmd = AppData.PgDataSource.CreateCommand(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3");
        cmd.Parameters.AddWithValue(min);
        cmd.Parameters.AddWithValue(max);
        cmd.Parameters.AddWithValue(limit);
        await using var reader = await cmd.ExecuteReaderAsync();

        var items = new List<DbItemDto>(limit);
        while (await reader.ReadAsync())
        {
            items.Add(ReadNpgsqlItem(reader));
        }

        return TypedResults.Json(new DbResponseDto(items, items.Count), AppJsonContext.Default.DbResponseDto);
    }

    static void ReadPriceRange(HttpRequest req, out int min, out int max)
    {
        min = 10;
        max = 50;

        if (req.Query.TryGetValue("min", out var minValue) && int.TryParse(minValue, out var parsedMin))
        {
            min = parsedMin;
        }

        if (req.Query.TryGetValue("max", out var maxValue) && int.TryParse(maxValue, out var parsedMax))
        {
            max = parsedMax;
        }
    }

    static DbItemDto ReadSqliteItem(SqliteDataReader reader)
    {
        return new DbItemDto
        {
            Id = reader.GetInt32(0),
            Name = reader.GetString(1),
            Category = reader.GetString(2),
            Price = reader.GetInt32(3),
            Quantity = reader.GetInt32(4),
            Active = reader.GetInt32(5) == 1,
            Tags = JsonSerializer.Deserialize(reader.GetString(6), AppJsonContext.Default.ListString) ?? [],
            Rating = new RatingInfo
            {
                Score = reader.GetInt32(7),
                Count = reader.GetInt32(8)
            }
        };
    }

    static DbItemDto ReadNpgsqlItem(NpgsqlDataReader reader)
    {
        return new DbItemDto
        {
            Id = reader.GetInt32(0),
            Name = reader.GetString(1),
            Category = reader.GetString(2),
            Price = reader.GetInt32(3),
            Quantity = reader.GetInt32(4),
            Active = reader.GetBoolean(5),
            Tags = JsonSerializer.Deserialize(reader.GetString(6), AppJsonContext.Default.ListString) ?? [],
            Rating = new RatingInfo
            {
                Score = reader.GetInt32(7),
                Count = reader.GetInt32(8)
            }
        };
    }

}
