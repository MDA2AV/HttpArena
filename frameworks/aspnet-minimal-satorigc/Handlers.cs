
using HttpArena.Services;
using HttpArena.Types;
using System.Buffers;

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

    // Echo: the bytes that arrived go back unchanged.
    //
    // When the request declares its length - which it does on this profile - the
    // body is read once into a pooled buffer of exactly that size and written
    // once. The obvious `new MemoryStream()` costs twice over: it doubles as it
    // grows, so reaching 100 KB takes ~10 allocations and a full recopy, and its
    // final buffer lands above the 85,000-byte Large Object Heap threshold, which
    // is collected as gen2 and not compacted. ArrayPool hands back the same
    // buffer instead of allocating one per request. Measured at -12% CPU on the
    // 8Gbit profile, with a tighter p99.
    //
    // A chunked request carries no length to size against, so it keeps the
    // collect-then-write path - which is also what makes that case correct.
    public static async Task EchoBody(HttpContext ctx)
    {
        ctx.Response.ContentType = "application/octet-stream";

        if (ctx.Request.ContentLength is long cl && cl > 0)
        {
            int len = (int)cl;
            byte[] buf = ArrayPool<byte>.Shared.Rent(len);
            try
            {
                await ctx.Request.Body.ReadExactlyAsync(buf.AsMemory(0, len));
                ctx.Response.ContentLength = len;
                await ctx.Response.Body.WriteAsync(buf.AsMemory(0, len));
            }
            finally
            {
                ArrayPool<byte>.Shared.Return(buf);
            }
            return;
        }

        using var ms = new MemoryStream();
        await ctx.Request.Body.CopyToAsync(ms);
        var body = ms.GetBuffer().AsMemory(0, (int)ms.Length);
        ctx.Response.ContentLength = body.Length;
        await ctx.Response.Body.WriteAsync(body);
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
