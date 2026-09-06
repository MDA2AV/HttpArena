using EffinitiveFramework.Core;

namespace effinitive.Tests;

public class DelayEndpoint : NoRequestAsyncEndpointBase<string>
{
    protected override string Method => "GET";
    protected override string Route => "/delay/{ms}";
    protected override string ContentType => "text/plain";

    public override async Task<string> HandleAsync(CancellationToken ct)
    {
        var raw = HttpContext?.RouteValues?["ms"]?.ToString();
        if (!int.TryParse(raw, out var ms) || ms < 0)
            throw new ArgumentException($"Invalid delay in path: '{raw}'");

        if (ms > 0)
            await Task.Delay(ms, ct);

        return ms.ToString();
    }
}
