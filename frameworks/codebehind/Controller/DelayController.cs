using CodeBehind;

public partial class DelayController : CodeBehindController
{
    public async Task PageLoad(HttpContext context)
    {
        if (Segment.Count() == 0 || !int.TryParse(Segment.GetValue(0), out var ms))
        {
            context.Response.StatusCode = 400;
            context.Response.ContentType = "text/plain";
            Write("Bad Request: ms required");
            return;
        }

        if (ms > 0)
            await Task.Delay(ms);

        context.Response.ContentType = "text/plain";
        Write(ms.ToString());
    }
}