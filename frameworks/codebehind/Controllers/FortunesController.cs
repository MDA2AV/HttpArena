using System.Data.Common;

using HttpArena.Data;
using HttpArena.Models;

namespace HttpArena;

/// <summary>
/// GET /fortunes renders wwwroot/fortunes.aspx with the fortune rows.
/// </summary>
public sealed class FortunesController : HttpArenaController
{
    public new async Task PageLoad(HttpContext context)
    {
        if (!AllowMethod(context, HttpMethods.Get))
        {
            return;
        }

        // Registered only when DATABASE_URL is set.
        var service = context.RequestServices.GetService<FortuneService>();

        if (service is null)
        {
            Status(context, StatusCodes.Status503ServiceUnavailable);
            return;
        }

        List<Fortune> fortunes;

        try
        {
            fortunes = await service.GetFortunesAsync(context.RequestAborted);
        }
        catch (DbException)
        {
            // CodeBehind answers 200 with an empty body when a controller throws.
            Status(context, StatusCodes.Status500InternalServerError);
            return;
        }

        // CodeBehind writes the page without a content type.
        context.Response.ContentType = "text/html; charset=utf-8";

        View("/fortunes.aspx", new FortunesModel { Fortunes = fortunes });
    }
}
