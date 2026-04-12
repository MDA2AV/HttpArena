using Microsoft.AspNetCore.Mvc;

using System.Text.Json;

[ApiController]
public class TestController : ControllerBase
{

    [HttpGet("/pipeline")]
    public string Pipeline() => "ok";

    [HttpGet("/baseline11")]
    public int Sum([FromQuery] int a, [FromQuery] int b) => a + b;

    [HttpPost("/baseline11")]
    public async Task<int> SumBody([FromQuery] int a, [FromQuery] int b)
    {
        using var reader = new StreamReader(Request.Body);
        return a + b + int.Parse(await reader.ReadToEndAsync());
    }

    [HttpGet("/baseline2")]
    public int Baseline2([FromQuery] int a, [FromQuery] int b) => a + b;

    [HttpPost("/upload")]
    public async Task<IActionResult> Upload()
    {
        long size = 0;
        var buffer = new byte[65536];
        int read;
        while ((read = await Request.Body.ReadAsync(buffer)) > 0)
            size += read;

        return Content(size.ToString());
    }

    [HttpGet("/json/{count}")]
    public IActionResult Json(int count)
    {
        if (AppData.DatasetItems == null)
            return Problem("Dataset not loaded");

        if (count > AppData.DatasetItems.Count) count = AppData.DatasetItems.Count;
        if (count < 0) count = 0;

        int m = 1;
        if (Request.Query.TryGetValue("m", out var mVal) && int.TryParse(mVal, out var pm)) m = pm;

        var items = new List<ProcessedItem>(count);
        for (int i = 0; i < count; i++)
        {
            var item = AppData.DatasetItems[i];
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
                Total = item.Price * item.Quantity * m
            });
        }
        return Ok(new { items, count });
    }

    [HttpGet("/db")]
    public IActionResult Database([FromQuery] int min = 10, [FromQuery] int max = 50)
    {
        if (AppData.DbPool == null)
            return Problem("DB not available");

        var conn = AppData.DbPool.Rent();
        try
        {
            using var cmd = conn.CreateCommand();
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
                    price = reader.GetInt32(3),
                    quantity = reader.GetInt32(4),
                    active = reader.GetInt32(5) == 1,
                    tags = JsonSerializer.Deserialize<List<string>>(reader.GetString(6)),
                    rating = new { score = reader.GetInt32(7), count = reader.GetInt32(8) },
                });
            }
            return Ok(new { items, count = items.Count });
        }
        finally
        {
            AppData.DbPool.Return(conn);
        }
    }

    [HttpGet("/async-db")]
    public async Task<IActionResult> AsyncDatabase([FromQuery] int min = 10, [FromQuery] int max = 50, [FromQuery] int limit = 50)
    {
        if (AppData.PgDataSource == null)
            return Ok(new { items = Array.Empty<object>(), count = 0 });

        limit = Math.Clamp(limit, 1, 50);

        await using var cmd = AppData.PgDataSource.CreateCommand(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3");
        cmd.Parameters.AddWithValue(min);
        cmd.Parameters.AddWithValue(max);
        cmd.Parameters.AddWithValue(limit);
        await using var reader = await cmd.ExecuteReaderAsync();

        var items = new List<object>(limit);
        while (await reader.ReadAsync())
        {
            items.Add(new
            {
                id = reader.GetInt32(0),
                name = reader.GetString(1),
                category = reader.GetString(2),
                price = reader.GetInt32(3),
                quantity = reader.GetInt32(4),
                active = reader.GetBoolean(5),
                tags = JsonSerializer.Deserialize<List<string>>(reader.GetString(6)),
                rating = new { score = reader.GetInt32(7), count = reader.GetInt32(8) },
            });
        }
        return Ok(new { items, count = items.Count });
    }

}