using GenHTTP.Modules.Reflection;
using GenHTTP.Modules.Webservices;

namespace genhttp.Tests;

public class Echo
{

    /// <summary>
    /// The bytes that arrived, unchanged. Returning a Stream rather than a
    /// byte[] keeps GenHTTP on its raw response path instead of serializing;
    /// the body is collected first because the response cannot be framed until
    /// its length is known, which is also what makes a chunked request work.
    /// </summary>
    [ResourceMethod(Method.Post)]
    public async ValueTask<Stream> Compute(Stream input)
    {
        var buffer = new MemoryStream();

        await input.CopyToAsync(buffer);

        buffer.Position = 0;

        return buffer;
    }

}
