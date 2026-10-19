namespace HttpArena;

/// <summary>
/// GET /pipeline answers "ok".
/// </summary>
public sealed class PipelineController : HttpArenaController
{
    public new void PageLoad(HttpContext context)
    {
        if (AllowMethod(context, HttpMethods.Get))
        {
            Text(context, "ok");
        }
    }
}
