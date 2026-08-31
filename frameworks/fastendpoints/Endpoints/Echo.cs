using FastEndpoints;

namespace HttpArena.Endpoints;

public sealed class EchoEndpoint : EndpointWithoutRequest
{
    public override void Configure()
    {
        Post("/echo");
        AllowAnonymous();
    }

    // Collected before replying: the response needs a Content-Length, and a
    // chunked request carries none to forward until the body is in.
    public override async Task HandleAsync(CancellationToken ct)
    {
        using var ms = new MemoryStream();
        await HttpContext.Request.Body.CopyToAsync(ms, ct);
        await Send.BytesAsync(ms.ToArray(), contentType: "application/octet-stream", cancellation: ct);
    }
}
