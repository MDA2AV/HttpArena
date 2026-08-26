using System.Buffers;

using HttpArena.Services;
using HttpArena.Types;

static class Handlers
{
    
    public static string Sum(int a, int b) => (a + b).ToString();

    public static async ValueTask<string> SumBody(int a, int b, HttpRequest req)
    {
        using var reader = new StreamReader(req.Body);
        return (a + b + int.Parse(await reader.ReadToEndAsync())).ToString();
    }

    public static string Text() => "ok";

    // GET /delay/{ms} - answer after ms milliseconds. Task.Delay registers a
    // timer and yields; the thread goes back to the pool instead of sitting on
    // the request, so the number of waits in flight is bounded by memory rather
    // than by the pool size.
    public static async ValueTask<string> Delay(int ms)
    {
        if (ms > 0) await Task.Delay(ms);
        return ms.ToString();
    }

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

    public static IResult Json(int count, DatasetService dataset, int m = 1)
    {
        var response = dataset.GetItems(count, m);

        if (response is null)
            return TypedResults.Problem("Dataset not loaded");

        return TypedResults.Ok(response);
    }

    public static async Task<IResult> AsyncDatabase(ItemService items, double min = 10, double max = 50, int limit = 50)
    {
        if (!items.IsAvailable)
            return TypedResults.Problem("DB not available");

        var response = await items.QueryAsync(min, max, limit);

        return TypedResults.Ok(response);
    }

    public static async Task<IResult> CrudList(ItemService items, string? category = null, int page = 0, int limit = 0)
    {
        if (!items.IsAvailable)
            return TypedResults.Problem("DB not available");

        var response = await items.ListAsync(category, page, limit);

        return TypedResults.Ok(response);
    }

    public static async Task<IResult> CrudRead(int id, ItemService items, HttpContext ctx)
    {
        if (!items.IsAvailable)
            return TypedResults.Problem("DB not available");

        var result = await items.ReadAsync(id);
        if (result is null) return TypedResults.NotFound();

        ctx.Response.Headers["X-Cache"] = result.CacheHit ? "HIT" : "MISS";

        return result.Json is not null
            ? Results.Content(result.Json, "application/json")
            : TypedResults.Ok(result.Item!);
    }

    public static async Task<IResult> CrudCreate(CrudItemInput input, ItemService items)
    {
        if (!items.IsAvailable)
            return TypedResults.Problem("DB not available");

        var created = await items.CreateAsync(input);

        return TypedResults.Created((string?)null, created);
    }

    public static async Task<IResult> CrudUpdate(int id, CrudItemInput input, ItemService items)
    {
        if (!items.IsAvailable)
            return TypedResults.Problem("DB not available");

        var updated = await items.UpdateAsync(id, input);
        if (updated is null) return TypedResults.NotFound();

        return TypedResults.Ok(updated);
    }

}
