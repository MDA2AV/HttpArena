using FastEndpoints;

using HttpArena.Services;
using HttpArena.Types;

namespace HttpArena.Endpoints;

public sealed class ListItemsRequest
{
    public string? Category { get; set; }
    public int Page { get; set; }
    public int Limit { get; set; }
}

public sealed class ListItemsEndpoint(ItemService items) : Endpoint<ListItemsRequest, CrudListResponse>
{
    public override void Configure()
    {
        Get("/crud/items");
        AllowAnonymous();
    }

    public override async Task HandleAsync(ListItemsRequest req, CancellationToken ct)
    {
        if (!items.IsAvailable)
        {
            await Send.ResultAsync(TypedResults.Problem("DB not available"));
            return;
        }

        await Send.OkAsync(await items.ListAsync(req.Category, req.Page, req.Limit), ct);
    }
}

public sealed class ReadItemRequest
{
    public int Id { get; set; }
}

public sealed class ReadItemEndpoint(ItemService items) : Endpoint<ReadItemRequest>
{
    public override void Configure()
    {
        Get("/crud/items/{id}");
        AllowAnonymous();
    }

    public override async Task HandleAsync(ReadItemRequest req, CancellationToken ct)
    {
        if (!items.IsAvailable)
        {
            await Send.ResultAsync(TypedResults.Problem("DB not available"));
            return;
        }

        var result = await items.ReadAsync(req.Id);
        if (result is null)
        {
            await Send.NotFoundAsync(ct);
            return;
        }

        HttpContext.Response.Headers["X-Cache"] = result.CacheHit ? "HIT" : "MISS";

        if (result.Json is not null)
        {
            await Send.StringAsync(result.Json, contentType: "application/json", cancellation: ct);
        }
        else
        {
            await Send.OkAsync(result.Item!, ct);
        }
    }
}

public sealed class ItemWriteRequest
{
    public int Id { get; set; }
    public string? Name { get; set; }
    public string? Category { get; set; }
    public int Price { get; set; }
    public int Quantity { get; set; }

    public CrudItemInput ToInput() => new(Id, Name, Category, Price, Quantity);
}

public sealed class CreateItemEndpoint(ItemService items) : Endpoint<ItemWriteRequest, CrudWriteResponse>
{
    public override void Configure()
    {
        Post("/crud/items");
        AllowAnonymous();
    }

    public override async Task HandleAsync(ItemWriteRequest req, CancellationToken ct)
    {
        if (!items.IsAvailable)
        {
            await Send.ResultAsync(TypedResults.Problem("DB not available"));
            return;
        }

        var created = await items.CreateAsync(req.ToInput());

        await Send.ResponseAsync(created, 201, ct);
    }
}

public sealed class UpdateItemEndpoint(ItemService items) : Endpoint<ItemWriteRequest, CrudWriteResponse>
{
    public override void Configure()
    {
        Put("/crud/items/{id}");
        AllowAnonymous();
    }

    public override async Task HandleAsync(ItemWriteRequest req, CancellationToken ct)
    {
        if (!items.IsAvailable)
        {
            await Send.ResultAsync(TypedResults.Problem("DB not available"));
            return;
        }

        var updated = await items.UpdateAsync(req.Id, req.ToInput());
        if (updated is null)
        {
            await Send.NotFoundAsync(ct);
            return;
        }

        await Send.OkAsync(updated, ct);
    }
}
