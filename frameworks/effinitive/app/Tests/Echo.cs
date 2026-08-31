using EffinitiveFramework.Core;
using EffinitiveFramework.Core.Http;

namespace effinitive.Tests;

public class EchoEndpoint : NoRequestEndpointBase<byte[]>
{
    protected override string Method => "POST";
    protected override string Route => "/echo";
    protected override string ContentType => "application/octet-stream";

    // The bytes that arrived go back unchanged. ReadBodyAsync reads to end
    // regardless of framing, so a chunked request works without a
    // Content-Length to size it from.
    public override async ValueTask<byte[]> HandleAsync(CancellationToken ct)
        => (await HttpContext!.ReadBodyAsync(ct)).ToArray();
}
