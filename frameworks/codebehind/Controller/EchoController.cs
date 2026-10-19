using CodeBehind;
using System.Text;

public partial class EchoController : CodeBehindController
{
    public async Task PageLoad(HttpContext context)
    {
        using var reader = new StreamReader(context.Request.Body, Encoding.UTF8);
        var body = await reader.ReadToEndAsync();

        context.Response.ContentType = "application/octet-stream";
        Write(body);
    }
}