using CodeBehind;

public partial class PipelineController : CodeBehindController
{
    public void PageLoad(HttpContext context)
    {
        context.Response.ContentType = "text/plain";
        Write("ok");
    }
}