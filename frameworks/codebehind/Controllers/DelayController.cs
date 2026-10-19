namespace HttpArena;

/// <summary>
/// GET /delay/{ms} answers ms after waiting that many milliseconds. In route
/// mode the path after the controller name arrives as Segment.
/// </summary>
public sealed class DelayController : HttpArenaController
{
    public new async Task PageLoad(HttpContext context)
    {
        if (!AllowMethod(context, HttpMethods.Get))
        {
            return;
        }

        if (!int.TryParse(Segment.GetValue(0), out var milliseconds) || milliseconds < 0)
        {
            Status(context, StatusCodes.Status400BadRequest);
            return;
        }

        if (milliseconds > 0)
        {
            await Task.Delay(milliseconds, context.RequestAborted);
        }

        Text(context, milliseconds.ToString());
    }
}
