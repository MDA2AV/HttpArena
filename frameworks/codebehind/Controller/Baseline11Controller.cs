using CodeBehind;
using System.Text;

public partial class Baseline11Controller : CodeBehindController
{
    public async Task PageLoad(HttpContext context)
    {
        long total = 0;

        foreach (var pair in context.Request.Query)
            if (long.TryParse(pair.Value.ToString(), out var n))
                total += n;

        if (context.Request.ContentLength is > 0
            || context.Request.Headers.TransferEncoding.Count > 0)
        {
            using var reader = new StreamReader(context.Request.Body, Encoding.UTF8);
            var body = await reader.ReadToEndAsync();
            if (long.TryParse(body.Trim(), out var b))
                total += b;
        }

        context.Response.ContentType = "text/plain";
        Write(total.ToString());
    }
}