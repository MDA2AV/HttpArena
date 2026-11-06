using GenHTTP.Api.Content;
using GenHTTP.Api.Infrastructure;
using GenHTTP.Api.Protocol;

using genhttp.Content;

namespace genhttp.Handlers;

/// <summary>
/// Answers every request with the same, shared content.
/// </summary>
public sealed class FixedHandler(ReadOnlyMemory<byte> data, ContentType type) : IHandler
{
    private readonly FixedContent _content = new(data, type);

    public ValueTask PrepareAsync(IServer server) => ValueTask.CompletedTask;

    public ValueTask<IResponse?> HandleAsync(IRequest request)
        => new(request.Respond().Content(_content).Build());

}
