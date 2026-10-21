using CodeBehind;

public partial class EchoController : CodeBehindController
{
    public async Task PageLoad(HttpContext context)
    {
        using var ms = new MemoryStream();
        await context.Request.Body.CopyToAsync(ms);
        var bytes = ms.ToArray();

        context.Response.ContentType = "application/octet-stream";
        context.Response.ContentLength = bytes.Length;
        await context.Response.Body.WriteAsync(bytes);
    }
}
