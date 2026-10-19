using HttpArena.Data;

namespace HttpArena;

/// <summary>
/// GET /json/{count}?m= answers the first count dataset items with their totals.
/// </summary>
public sealed class JsonController : HttpArenaController
{
    public new void PageLoad(HttpContext context)
    {
        if (!AllowMethod(context, HttpMethods.Get))
        {
            return;
        }

        var dataset = context.RequestServices.GetRequiredService<DatasetService>();

        if (!dataset.IsAvailable)
        {
            Status(context, StatusCodes.Status503ServiceUnavailable);
            return;
        }

        var multiplier = 1;

        if (!int.TryParse(Segment.GetValue(0), out var count)
            || (context.Request.Query.TryGetValue("m", out var m) && !int.TryParse(m, out multiplier)))
        {
            Status(context, StatusCodes.Status400BadRequest);
            return;
        }

        Json(context, dataset.GetItems(count, multiplier), AppJsonContext.Default.ItemsResponseProcessedItem);
    }
}
