using FastEndpoints;

namespace HttpArena.Endpoints;

public sealed class PipelineEndpoint : EndpointWithoutRequest
{
    public override void Configure()
    {
        Get("/pipeline");
        AllowAnonymous();
    }

    public override Task HandleAsync(CancellationToken ct)
        => Send.StringAsync("ok", cancellation: ct);
}
