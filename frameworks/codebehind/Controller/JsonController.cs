using CodeBehind;
using System.Text.Json;

public partial class JsonController : CodeBehindController
{
    private static readonly JsonSerializerOptions JsonOpts = new(JsonSerializerDefaults.Web);

    public void PageLoad(HttpContext context)
    {
        if (Segment.Count() == 0 || !int.TryParse(Segment.GetValue(0), out var count))
        {
            context.Response.StatusCode = 400;
            context.Response.ContentType = "text/plain";
            Write("Bad Request: count required");
            return;
        }

        long m = 1;
        if (context.Request.Query.TryGetValue("m", out var raw)
            && long.TryParse(raw.ToString(), out var parsed))
            m = parsed;

        var dataset = context.RequestServices.GetRequiredService<DatasetService>();
        var all = dataset.Items;
        var n = Math.Min(count, all.Length);

        var items = new List<OutItem>(n);
        for (var i = 0; i < n; i++)
        {
            var d = all[i];
            items.Add(new OutItem
            {
                Id       = d.Id,
                Name     = d.Name,
                Category = d.Category,
                Price    = d.Price,
                Quantity = d.Quantity,
                Active   = d.Active,
                Tags     = d.Tags,
                Rating   = d.Rating,
                Total    = d.Price * d.Quantity * m,
            });
        }

        var json = JsonSerializer.Serialize(new OutList { Items = items, Count = n }, JsonOpts);
        context.Response.ContentType = "application/json";
        Write(json);
    }
}