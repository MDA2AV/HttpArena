namespace HttpArena;

/// <summary>
/// GET /baseline2?a=&amp;b= answers a + b (the HTTP/2 and HTTP/3 baseline).
/// </summary>
public sealed class Baseline2Controller : HttpArenaController
{
    public new void PageLoad(HttpContext context)
    {
        if (!AllowMethod(context, HttpMethods.Get))
        {
            return;
        }

        if (!int.TryParse(context.Request.Query["a"], out var a) || !int.TryParse(context.Request.Query["b"], out var b))
        {
            Status(context, StatusCodes.Status400BadRequest);
            return;
        }

        Text(context, (a + b).ToString());
    }
}
