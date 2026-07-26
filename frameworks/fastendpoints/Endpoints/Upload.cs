using System.Buffers;

using FastEndpoints;

namespace HttpArena.Endpoints;

public sealed class UploadEndpoint : EndpointWithoutRequest
{
    public override void Configure()
    {
        Post("/upload");
        AllowAnonymous();
    }

    public override async Task HandleAsync(CancellationToken ct)
    {
        long size = 0;
        var buffer = ArrayPool<byte>.Shared.Rent(65536);
        try
        {
            int read;
            while ((read = await HttpContext.Request.Body.ReadAsync(buffer.AsMemory(0, buffer.Length), ct)) > 0)
            {
                size += read;
            }
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
        }

        await Send.StringAsync(size.ToString(), cancellation: ct);
    }
}
