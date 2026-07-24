using EffinitiveFramework.Core;
using EffinitiveFramework.Core.Http;

namespace effinitive.Tests;

public class UploadEndpoint : NoRequestEndpointBase<string>
{
    protected override string Method => "POST";
    protected override string Route => "/upload";
    protected override string ContentType => "text/plain";

    public override async ValueTask<string> HandleAsync(CancellationToken ct)
        => (await HttpContext!.CountBodyBytesAsync(ct)).ToString();
}
