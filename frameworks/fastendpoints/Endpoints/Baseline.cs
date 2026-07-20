using FastEndpoints;

namespace HttpArena.Endpoints;

public sealed class SumRequest
{
    public int A { get; set; }
    public int B { get; set; }
}

public sealed class SumEndpoint : Endpoint<SumRequest>
{
    public override void Configure()
    {
        Get("/baseline11", "/baseline2");
        AllowAnonymous();
    }

    public override Task HandleAsync(SumRequest req, CancellationToken ct)
        => Send.StringAsync((req.A + req.B).ToString(), cancellation: ct);
}

public sealed class SumBodyEndpoint : EndpointWithoutRequest
{
    public override void Configure()
    {
        Post("/baseline11");
        AllowAnonymous();
    }

    public override async Task HandleAsync(CancellationToken ct)
    {
        var a = Query<int>("a");
        var b = Query<int>("b");

        using var reader = new StreamReader(HttpContext.Request.Body);
        var body = await reader.ReadToEndAsync(ct);

        await Send.StringAsync((a + b + int.Parse(body)).ToString(), cancellation: ct);
    }
}
