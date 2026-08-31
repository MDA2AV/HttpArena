using GenHTTP.Api.Content;
using GenHTTP.Api.Infrastructure;
using GenHTTP.Api.Protocol;

namespace genhttp.Tests;

public sealed class EchoHandler : IHandler
{

    public ValueTask PrepareAsync(IServer server) => ValueTask.CompletedTask;

    public ValueTask<IResponse?> HandleAsync(IRequest request)
    {
        if (request.Header.Method != RequestMethod.Post)
        {
            return new(request.Respond()
                              .Status(ResponseStatus.MethodNotAllowed)
                              .Build());
        }

        var body = request.GetBody(HeaderAccess.Release);

        if (body == null)
        {
            return new(request.Respond()
                              .Status(ResponseStatus.NoContent)
                              .Build());
        }

        return new(request.Respond()
                          .Content(new EchoContent(body))
                          .Build());
    }

}
