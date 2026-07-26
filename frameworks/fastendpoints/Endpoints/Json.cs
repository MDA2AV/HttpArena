using FastEndpoints;

using HttpArena.Services;
using HttpArena.Types;

namespace HttpArena.Endpoints;

public sealed class JsonRequest
{
    public int Count { get; set; }
    public int M { get; set; } = 1;
}

public sealed class JsonEndpoint(DatasetService dataset) : Endpoint<JsonRequest, ItemsResponse<ProcessedItem>>
{
    public override void Configure()
    {
        Get("/json/{count}");
        AllowAnonymous();
    }

    public override async Task HandleAsync(JsonRequest req, CancellationToken ct)
    {
        var response = dataset.GetItems(req.Count, req.M);

        if (response is null)
        {
            await Send.ResultAsync(TypedResults.Problem("Dataset not loaded"));
            return;
        }

        await Send.OkAsync(response, ct);
    }
}
