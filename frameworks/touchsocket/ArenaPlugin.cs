using System.Text;

using TouchSocket.Core;
using TouchSocket.Http;

using HttpMethod = TouchSocket.Http.HttpMethod;

namespace TouchSocketArena;

/// <summary>
/// The arena routes, answered from TouchSocket's HTTP plugin pipeline.
/// </summary>
/// <remarks>
/// A plugin is how TouchSocket exposes HTTP: it sees each request, answers the ones it recognises
/// and calls the next one for the rest. Dispatch is on the path's first segment, which is what the
/// component gives you - there is no router above it to declare routes with.
/// </remarks>
internal sealed class ArenaPlugin(Dataset dataset) : PluginBase, IHttpPlugin
{
    private static readonly Encoding Utf8 = new UTF8Encoding(false);

    public async Task OnHttpRequest(IHttpSessionClient client, HttpContextEventArgs e)
    {
        var request = e.Context.Request;
        var response = e.Context.Response;

        var url = request.RelativeURL;

        // Strip the query; TouchSocket parses it separately into Query.
        var question = url.IndexOf('?');
        var path = question < 0 ? url : url[..question];

        switch (First(path, out var rest))
        {
            case "baseline11":
            case "baseline2":
                await BaselineAsync(request, response);
                break;

            case "json":
                await JsonAsync(request, response, rest);
                break;

            case "pipeline":
                await TextAsync(response, "ok");
                break;

            case "delay":
                await DelayAsync(response, rest);
                break;

            default:
                response.StatusCode = 404;
                await response.AnswerAsync();
                break;
        }

        e.Handled = true;
    }

    // GET /baseline11?a=1&b=2 - the sum as text. POST adds the body to it.
    private async Task BaselineAsync(HttpRequest request, HttpResponse response)
    {
        var total = Number(request, "a") + Number(request, "b");

        if (request.Method == HttpMethod.Post)
        {
            var body = await request.GetContentAsync();

            if (body.Length > 0 && int.TryParse(Utf8.GetString(body.Span), out var fromBody))
            {
                total += fromBody;
            }
        }

        await TextAsync(response, total.ToString());
    }

    // GET /delay/{ms} - answer after the wait, echoing the value back.
    private async Task DelayAsync(HttpResponse response, string rest)
    {
        if (!int.TryParse(rest, out var ms) || ms < 0)
        {
            response.StatusCode = 404;
            await response.AnswerAsync();
            return;
        }

        if (ms > 0)
        {
            // Registers a timer and yields rather than holding a thread, so the waits in flight are
            // bounded by memory instead of the pool.
            await Task.Delay(ms);
        }

        await TextAsync(response, ms.ToString());
    }

    // GET /json/{count}?m={multiplier}
    private async Task JsonAsync(HttpRequest request, HttpResponse response, string rest)
    {
        if (!int.TryParse(rest, out var count))
        {
            response.StatusCode = 404;
            await response.AnswerAsync();
            return;
        }

        var multiplier = int.TryParse(request.Query["m"], out var m) ? m : 1;

        var accepted = request.Headers["Accept-Encoding"].ToString() ?? string.Empty;

        var body = dataset.Render(count, multiplier,
                                  accepted.Contains("br", StringComparison.OrdinalIgnoreCase),
                                  accepted.Contains("gzip", StringComparison.OrdinalIgnoreCase),
                                  out var encoding);

        if (body is null)
        {
            response.StatusCode = 503;
            await response.AnswerAsync();
            return;
        }

        response.StatusCode = 200;
        response.Headers.Add("Vary", "Accept-Encoding");

        if (encoding is not null)
        {
            response.Headers.Add("Content-Encoding", encoding);
        }

        response.Content = new ReadonlyMemoryHttpContent(body, "application/json");
        await response.AnswerAsync();
    }

    private static async Task TextAsync(HttpResponse response, string value)
    {
        response.StatusCode = 200;
        response.Content = new StringHttpContent(value, Utf8, "text/plain");
        await response.AnswerAsync();
    }

    private static int Number(HttpRequest request, string name)
        => int.TryParse(request.Query[name], out var value) ? value : 0;

    // The first path segment, with whatever follows it in `rest`.
    private static string First(string path, out string rest)
    {
        var start = path.Length > 0 && path[0] == '/' ? 1 : 0;
        var end = path.IndexOf('/', start);

        if (end < 0)
        {
            rest = "";
            return path[start..];
        }

        rest = path[(end + 1)..];
        return path[start..end];
    }
}
