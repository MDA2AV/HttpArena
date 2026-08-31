using GenHTTP.Api.Infrastructure;
using GenHTTP.Api.Protocol;

namespace genhttp.Tests;

public sealed class EchoContent(IRequestBody body) : IResponseContent
{
    
    public ulong? Length => null;

    public ContentType? Type => ContentType.ApplicationOctetStream;

    public ReadOnlyMemory<byte>? Encoding => null;
    
    public ValueTask<ulong?> CalculateChecksumAsync() => new();
    
    public async ValueTask WriteAsync(IResponseSink sink)
    {
        var stream = body.AsStream();
        var writer = sink.Writer;

        while (true)
        {
            var memory = writer.GetMemory(BufferSize.Write);

            var read = await stream.ReadAsync(memory);

            if (read == 0)
            {
                break;
            }

            writer.Advance(read);
        }
    }

}
