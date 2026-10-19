namespace HttpArena;

/// <summary>
/// POST /echo answers the request body unchanged.
/// </summary>
public sealed class EchoController : HttpArenaController
{
    public new async Task PageLoad(HttpContext context)
    {
        if (!AllowMethod(context, HttpMethods.Post))
        {
            return;
        }

        // Write() only takes text, and the body is arbitrary bytes, so this is
        // the one controller that streams through the ASP.NET Core response.
        var response = context.Response;

        response.ContentType = "application/octet-stream";
        response.ContentLength = context.Request.ContentLength;

        await context.Request.Body.CopyToAsync(response.Body, context.RequestAborted);

        IgnoreAll();
    }
}
