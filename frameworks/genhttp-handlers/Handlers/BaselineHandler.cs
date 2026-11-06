using GenHTTP.Api.Content;
using GenHTTP.Api.Infrastructure;
using GenHTTP.Api.Protocol;

using genhttp.Content;

namespace genhttp.Handlers;

/// <summary>
/// Sums the query parameters a and b and, if present, the number in the body.
/// </summary>
public sealed class BaselineHandler : IHandler
{

    public ValueTask PrepareAsync(IServer server) => ValueTask.CompletedTask;

    public ValueTask<IResponse?> HandleAsync(IRequest request)
    {
        // the header needs to be read before the body is opened, as the
        // body is fetched without retaining the header
        var query = request.Header.Query;

        var sum = Parameters.Query(query, "a"u8, 0) + Parameters.Query(query, "b"u8, 0);

        if (!request.HasBody)
        {
            return new(Respond(request, sum));
        }

        var body = request.GetBody(HeaderAccess.Release);

        if (body == null)
        {
            return new(Respond(request, sum));
        }

        var pending = body.AsMemoryAsync();

        if (pending.IsCompletedSuccessfully)
        {
            return new(Respond(request, sum + ParseBody(pending.Result)));
        }

        return HandleAsync(request, sum, pending);
    }

    private static async ValueTask<IResponse?> HandleAsync(IRequest request, int sum, ValueTask<ReadOnlyMemory<byte>> pending)
    {
        var body = await pending;

        return Respond(request, sum + ParseBody(body));
    }

    private static int ParseBody(ReadOnlyMemory<byte> body)
    {
        if (body.IsEmpty)
        {
            return 0;
        }

        if (!Parameters.TryParse(body.Span, out var value))
        {
            throw new ProviderException(ResponseStatus.BadRequest, "Body must be an integer");
        }

        return value;
    }

    private static IResponse Respond(IRequest request, long value)
        => request.Respond()
                  .Content(IntegerContent.From(value))
                  .Build();

}
