using FastEndpoints;

using HttpArena.Services;
using HttpArena.Types;

namespace HttpArena.Endpoints;

public sealed class RangeQueryRequest
{
    public double Min { get; set; } = 10;
    public double Max { get; set; } = 50;
    public int Limit { get; set; } = 50;
}

public sealed class AsyncDbEndpoint(ItemService items) : Endpoint<RangeQueryRequest, ItemsResponse<Item>>
{
    public override void Configure()
    {
        Get("/async-db");
        AllowAnonymous();
    }

    public override async Task HandleAsync(RangeQueryRequest req, CancellationToken ct)
    {
        if (!items.IsAvailable)
        {
            await Send.ResultAsync(TypedResults.Problem("DB not available"));
            return;
        }

        await Send.OkAsync(await items.QueryAsync(req.Min, req.Max, req.Limit), ct);
    }
}
