using System.Buffers;

using HttpArena.Services;

using Microsoft.AspNetCore.Mvc;

[ApiController]
public class TestController(DatasetService dataset, ItemService items) : ControllerBase
{

    [HttpGet("/pipeline")]
    public string Pipeline() => "ok";

    [HttpGet("/baseline11")]
    public string Sum([FromQuery] int a, [FromQuery] int b) => (a + b).ToString();

    [HttpPost("/baseline11")]
    public async Task<string> SumBody([FromQuery] int a, [FromQuery] int b)
    {
        using var reader = new StreamReader(Request.Body);
        return (a + b + int.Parse(await reader.ReadToEndAsync())).ToString();
    }

    [HttpGet("/baseline2")]
    public string Baseline2([FromQuery] int a, [FromQuery] int b) => (a + b).ToString();

    [HttpPost("/upload")]
    public async Task<string> Upload()
    {
        long size = 0;
        var buffer = ArrayPool<byte>.Shared.Rent(65536);
        try
        {
            int read;
            while ((read = await Request.Body.ReadAsync(buffer.AsMemory(0, buffer.Length))) > 0)
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

    [HttpGet("/json/{count}")]
    public IActionResult Json(int count, [FromQuery] int m = 1)
    {
        var response = dataset.GetItems(count, m);

        if (response is null)
            return Problem("Dataset not loaded");

        return Ok(response);
    }

    [HttpGet("/async-db")]
    public async Task<IActionResult> AsyncDatabase([FromQuery] double min = 10, [FromQuery] double max = 50, [FromQuery] int limit = 50)
    {
        if (!items.IsAvailable)
            return Problem("DB not available");

        return Ok(await items.QueryAsync(min, max, limit));
    }

}
