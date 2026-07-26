using EffinitiveFramework.Core;
using EffinitiveFramework.Core.Http;

namespace effinitive.Tests;

public class PipelineEndpoint : NoRequestEndpointBase<string>
{
    protected override string Method => "GET";
    protected override string Route => "/pipeline";
    protected override string ContentType => "text/plain";

    public override ValueTask<string> HandleAsync(CancellationToken ct)
        => ValueTask.FromResult("ok");
}

public class BaselineGetEndpoint : NoRequestEndpointBase<string>
{
    protected override string Method => "GET";
    protected override string Route => "/baseline11";
    protected override string ContentType => "text/plain";

    public override ValueTask<string> HandleAsync(CancellationToken ct)
    {
        var query = HttpContext?.Query ?? QueryCollection.Empty;
        int a = query.GetInt("a");
        int b = query.GetInt("b");
        return ValueTask.FromResult((a + b).ToString());
    }
}

public class BaselinePostEndpoint : EndpointBase<string, string>
{
    protected override string Method => "POST";
    protected override string Route => "/baseline11";
    protected override string ContentType => "text/plain";

    public override ValueTask<string> HandleAsync(string body, CancellationToken ct = default)
    {
        var query = HttpContext?.Query ?? QueryCollection.Empty;
        int a = query.GetInt("a");
        int b = query.GetInt("b");
        int.TryParse(body.Trim(), out var bodyVal);
        return ValueTask.FromResult((a + b + bodyVal).ToString());
    }
}

public class Baseline2GetEndpoint : NoRequestEndpointBase<string>
{
    protected override string Method => "GET";
    protected override string Route => "/baseline2";
    protected override string ContentType => "text/plain";

    public override ValueTask<string> HandleAsync(CancellationToken ct)
    {
        var query = HttpContext?.Query ?? QueryCollection.Empty;
        int a = query.GetInt("a");
        int b = query.GetInt("b");
        return ValueTask.FromResult((a + b).ToString());
    }
}
