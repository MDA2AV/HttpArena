using FastEndpoints;

namespace HttpArena.Endpoints;

public sealed class DelayRequest
{
    public int Ms { get; set; }
}

/// The async profile: hold the request for the requested number of milliseconds, then answer.
/// Task.Delay registers a timer and yields, so the thread goes back to the pool rather than
/// sitting on the request and the waits in flight are bounded by memory.
public sealed class DelayEndpoint : Endpoint<DelayRequest>
{
    public override void Configure()
    {
        Get("/delay/{ms}");
        AllowAnonymous();
    }

    public override async Task HandleAsync(DelayRequest req, CancellationToken ct)
    {
        if (req.Ms > 0)
        {
            await Task.Delay(req.Ms, ct);
        }

        await Send.StringAsync(req.Ms.ToString(), cancellation: ct);
    }
}
