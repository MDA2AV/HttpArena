// The site itself, at the root of resources/ beside the database's migrations: what
// scripts/gen_leaderboard_data.py generated and scripts/assemble_site.sh laid out - the same tree
// GitHub Pages serves - which scripts/publish_genhttp.py puts into every version it saves. It is
// never written by hand. It has no folder of its own because the platform takes resource names at
// most six deep, and the deepest docs pages already are.
//
// A folder answers with its index.html (docs/scoring/ is docs/scoring/index.html), a path that is
// nothing answers 404 with the site's own 404.html, and migrations/ is not served. A version saved
// without the site - a clone that never had it built - says so instead of failing.

public static class Site
{
    public static IHandlerBuilder Create()
    {
        if (!Resources.Exists("index.html"))
        {
            return Inline.Create().Get((IRequest request) => request.Respond()
                                                                    .Status(ResponseStatus.ServiceUnavailable)
                                                                    .Content("This version was saved without the site: scripts/publish_genhttp.py builds it into resources/.", new ContentType("text/plain; charset=utf-8")));
        }

        var notFound = new NotFoundPage(Resources.Exists("404.html") ? Resources.ReadText("404.html") : "<!doctype html><title>Not found</title><p>Not found.</p>");

        return Layout.Create()
                     .Add("migrations", notFound)
                     .Add(new Folders(StaticWebsite.From(Resources.Tree()).Build(), notFound))
                     .Add(notFound);
    }
}

/// <summary>
/// Folders the way GitHub Pages serves them, which the static website handler does not quite: a
/// folder answers only where it has an index.html - left alone, two or more unknown segments
/// ending in a slash get the nearest index.html above them, with a 200 - and a folder asked for
/// without its slash is sent on to it, so docs/scoring is docs/scoring/.
/// </summary>
public sealed class Folders(IHandler website, IHandler notFound) : IHandler
{
    public ValueTask PrepareAsync(IServer server) => website.PrepareAsync(server);

    public ValueTask<IResponse> HandleAsync(IRequest request)
    {
        var target = request.Header.Target;

        var path = target.AsString(remainingOnly: true).Trim('/');

        if (path.Length == 0)
        {
            return website.HandleAsync(request);
        }

        if (path.Contains("..") || (target.HasTrailingSlash && !Has(path + "/index.html")))
        {
            return notFound.HandleAsync(request);
        }

        if (!target.HasTrailingSlash && !Has(path) && Has(path + "/index.html"))
        {
            // relative, as every address here is: "scoring/" from docs/scoring
            return ValueTask.FromResult(request.Respond()
                                               .Status(ResponseStatus.MovedPermanently)
                                               .Header("Location", path[(path.LastIndexOf('/') + 1)..] + "/")
                                               .Build());
        }

        return website.HandleAsync(request);
    }

    private static bool Has(string name)
    {
        try
        {
            return Resources.Exists(name);
        }
        catch (ArgumentException)
        {
            return false;
        }
    }
}

/// <summary>What answers when nothing else did: 404, with the site's page for it.</summary>
public sealed class NotFoundPage(string html) : IHandler
{
    private static readonly ContentType Html = new("text/html; charset=utf-8");

    public ValueTask PrepareAsync(IServer server) => ValueTask.CompletedTask;

    public ValueTask<IResponse> HandleAsync(IRequest request)
        => ValueTask.FromResult(request.Respond().Status(ResponseStatus.NotFound).Content(html, Html).Build());
}
