namespace HttpArena;

/// <summary>
/// GET /baseline11?a=&amp;b= answers a + b; POST adds the integer in the body.
/// </summary>
public sealed class Baseline11Controller : HttpArenaController
{
    public new async Task PageLoad(HttpContext context)
    {
        var request = context.Request;

        if (!HttpMethods.IsGet(request.Method) && !HttpMethods.IsPost(request.Method))
        {
            context.Response.Headers.Allow = "GET, POST";
            Status(context, StatusCodes.Status405MethodNotAllowed);
            return;
        }

        if (!int.TryParse(request.Query["a"], out var a) || !int.TryParse(request.Query["b"], out var b))
        {
            Status(context, StatusCodes.Status400BadRequest);
            return;
        }

        var sum = a + b;

        if (HttpMethods.IsPost(request.Method))
        {
            using var reader = new StreamReader(request.Body);

            if (!int.TryParse(await reader.ReadToEndAsync(context.RequestAborted), out var body))
            {
                Status(context, StatusCodes.Status400BadRequest);
                return;
            }

            sum += body;
        }

        Text(context, sum.ToString());
    }
}
