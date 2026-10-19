using System.Data.Common;

using HttpArena.Data;

namespace HttpArena;

/// <summary>
/// GET /async-db?min=&amp;max=&amp;limit= answers the items priced in range.
/// Class names can't contain a dash: with put_two_underlines_equal_to_dash_for_controller
/// set in code_behind/options.ini, CodeBehind routes "async-db" to Async__Db.
/// </summary>
public sealed class Async__DbController : HttpArenaController
{
    public new async Task PageLoad(HttpContext context)
    {
        if (!AllowMethod(context, HttpMethods.Get))
        {
            return;
        }

        // Registered only when DATABASE_URL is set.
        var items = context.RequestServices.GetService<ItemService>();

        if (items is null)
        {
            Status(context, StatusCodes.Status503ServiceUnavailable);
            return;
        }

        var query = context.Request.Query;

        var min = 10;
        var max = 50;
        var limit = 50;

        if ((query.TryGetValue("min", out var minValue) && !int.TryParse(minValue, out min))
            || (query.TryGetValue("max", out var maxValue) && !int.TryParse(maxValue, out max))
            || (query.TryGetValue("limit", out var limitValue) && !int.TryParse(limitValue, out limit)))
        {
            Status(context, StatusCodes.Status400BadRequest);
            return;
        }

        try
        {
            var result = await items.QueryAsync(min, max, Math.Clamp(limit, 1, 50), context.RequestAborted);

            Json(context, result, AppJsonContext.Default.ItemsResponseItem);
        }
        catch (DbException)
        {
            // CodeBehind answers 200 with an empty body when a controller throws.
            Status(context, StatusCodes.Status500InternalServerError);
        }
    }
}
