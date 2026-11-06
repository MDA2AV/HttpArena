using GenHTTP.Api.Content;
using GenHTTP.Api.Infrastructure;
using GenHTTP.Api.Protocol;

using genhttp.Content;

namespace genhttp.Handlers;

/// <summary>
/// Returns the body of the request as it was sent.
/// </summary>
public sealed class EchoHandler : IHandler
{

    public ValueTask PrepareAsync(IServer server) => ValueTask.CompletedTask;

    public ValueTask<IResponse?> HandleAsync(IRequest request)
    {
        var body = request.GetBody(HeaderAccess.Release);

        if (body == null)
        {
            return new(Respond(request, ReadOnlyMemory<byte>.Empty));
        }

        var pending = body.AsMemoryAsync();

        if (pending.IsCompletedSuccessfully)
        {
            return new(Respond(request, pending.Result));
        }

        return HandleAsync(request, pending);
    }

    private static async ValueTask<IResponse?> HandleAsync(IRequest request, ValueTask<ReadOnlyMemory<byte>> pending)
        => Respond(request, await pending);

    private static IResponse Respond(IRequest request, ReadOnlyMemory<byte> data)
        => request.Respond()
                  .Content(EchoContent.From(data))
                  .Build();

}
