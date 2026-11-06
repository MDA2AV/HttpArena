using GenHTTP.Api.Content;
using GenHTTP.Api.Infrastructure;
using GenHTTP.Api.Protocol;

using genhttp.Content;

namespace genhttp.Handlers;

/// <summary>
/// The async profile: hold the request for the requested number of milliseconds, then answer.
/// </summary>
/// <remarks>
/// Task.Delay registers a timer and yields, so the thread goes back to the pool rather than
/// sitting on the request and the number of waits in flight is bounded by memory.
/// </remarks>
public sealed class DelayHandler : IHandler
{

    public ValueTask PrepareAsync(IServer server) => ValueTask.CompletedTask;

    public ValueTask<IResponse?> HandleAsync(IRequest request)
    {
        if (!Parameters.TryPath(request.Header.Target, out var ms))
        {
            throw new ProviderException(ResponseStatus.BadRequest, "Delay must be an integer");
        }

        if (ms <= 0)
        {
            return new(Respond(request, ms));
        }

        return WaitAsync(request, ms);
    }

    private static async ValueTask<IResponse?> WaitAsync(IRequest request, int ms)
    {
        await Task.Delay(ms);

        return Respond(request, ms);
    }

    private static IResponse Respond(IRequest request, int ms)
        => request.Respond()
                  .Content(IntegerContent.From(ms))
                  .Build();

}
