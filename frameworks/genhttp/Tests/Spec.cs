using System.Text;

using GenHTTP.Api.Protocol;
using GenHTTP.Modules.Reflection;
using GenHTTP.Modules.Webservices;

namespace genhttp.Tests;

/// <summary>
/// /spec, the compliance route (site/content/docs/test-profiles/compliance/):
/// what Http11Probe and h2spec need from one route.
/// </summary>
public class Spec
{

    // A fixed body of at least five bytes - h2spec skips a flow-control test
    // below that. [ResourceMethod] maps GET alone, so HEAD has a method of its
    // own; the engine drops the body of a HEAD response itself.
    [ResourceMethod]
    public string Text() => "spec ok";

    [ResourceMethod(Method.Head)]
    public string Head() => "spec ok";

    // A response without content starts out as 204 in the internal engine,
    // so the status is set: the contract asks for 200.
    [ResourceMethod(Method.Options)]
    public IResponse Options(IRequest request) => request.Respond()
                                                         .Status(ResponseStatus.Ok)
                                                         .Header("Allow", "GET, HEAD, POST, OPTIONS")
                                                         .Build();

    [ResourceMethod(Method.Post)]
    public Stream Echo(Stream input) => input;

    // Every request header as the server stored it, one "Name: Value" line
    // each. The probe's normalization tests read this back to see what became
    // of a malformed header name. A body is read and discarded - after the
    // headers are listed, and not through a Stream argument: the framework
    // reads that with HeaderAccess.Release, which hands the header memory back.
    [ResourceMethod("headers")]
    public string Headers(IRequest request) => List(request);

    [ResourceMethod(Method.Post, "headers")]
    public async ValueTask<string> HeadersPost(IRequest request)
    {
        var headers = List(request);

        if (request.GetBody() is { } body)
        {
            await body.AsStream().CopyToAsync(Stream.Null);
        }

        return headers;
    }

    private static string List(IRequest request)
    {
        var headers = request.Header.Headers;
        var text = new StringBuilder();

        for (var i = 0; i < headers.Count; i++)
        {
            var entry = headers.GetMemoryEntry(i);

            text.Append(Encoding.Latin1.GetString(entry.Key.Span))
                .Append(": ")
                .Append(Encoding.Latin1.GetString(entry.Value.Span))
                .Append('\n');
        }

        return text.ToString();
    }

}
