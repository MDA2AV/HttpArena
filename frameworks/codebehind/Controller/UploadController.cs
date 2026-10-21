using CodeBehind;

public partial class UploadController : CodeBehindController
{
    public async Task PageLoad(HttpContext context)
    {
        using var ms = new MemoryStream();
        await context.Request.Body.CopyToAsync(ms);

        context.Response.ContentType = "text/plain";
        Write(ms.Length.ToString());
    }
}