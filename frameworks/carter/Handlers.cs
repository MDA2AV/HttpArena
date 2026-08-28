using System.Buffers;
using System.Text;
using System.Text.Json;

using Microsoft.AspNetCore.Http;

namespace HttpArena.Carter;

public static class Handlers
{
    private static readonly JsonSerializerOptions JsonOpts = new(JsonSerializerDefaults.Web);

    /// Sum of every query parameter whose value parses as an integer, plus the
    /// body when there is one. A non-numeric value is skipped rather than
    /// failing the request.
    public static async Task Baseline11(HttpContext ctx)
    {
        long total = 0;
        foreach (var pair in ctx.Request.Query)
        {
            if (long.TryParse(pair.Value.ToString(), out var n)) total += n;
        }

        if (ctx.Request.ContentLength is > 0 || ctx.Request.Headers.TransferEncoding.Count > 0)
        {
            using var reader = new StreamReader(ctx.Request.Body, Encoding.UTF8);
            var body = await reader.ReadToEndAsync();
            if (long.TryParse(body.Trim(), out var b)) total += b;
        }

        ctx.Response.ContentType = "text/plain";
        await ctx.Response.WriteAsync(total.ToString());
    }

    public static async Task JsonItems(HttpContext ctx, DatasetService dataset, int count)
    {
        long m = 1;
        if (ctx.Request.Query.TryGetValue("m", out var raw) && long.TryParse(raw.ToString(), out var parsed))
            m = parsed;

        var all = dataset.Items;
        var n = Math.Min(count, all.Length);
        var items = new List<OutItem>(n);
        for (var i = 0; i < n; i++)
        {
            var d = all[i];
            items.Add(new OutItem
            {
                Id = d.Id,
                Name = d.Name,
                Category = d.Category,
                Price = d.Price,
                Quantity = d.Quantity,
                Active = d.Active,
                Tags = d.Tags,
                Rating = d.Rating,
                Total = d.Price * d.Quantity * m,
            });
        }

        ctx.Response.ContentType = "application/json";
        await JsonSerializer.SerializeAsync(ctx.Response.Body, new OutList { Items = items, Count = n }, JsonOpts);
    }

    /// Counts the body without keeping it: a 20 MB upload goes through one
    /// rented 64 KB buffer.
    public static async Task Upload(HttpContext ctx)
    {
        var buffer = ArrayPool<byte>.Shared.Rent(64 * 1024);
        long total = 0;
        try
        {
            int read;
            while ((read = await ctx.Request.Body.ReadAsync(buffer)) > 0) total += read;
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
        }

        ctx.Response.ContentType = "text/plain";
        await ctx.Response.WriteAsync(total.ToString());
    }
}
