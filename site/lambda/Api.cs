// api/: the results and entries as JSON, for anybody, and api/ingest/, where the HttpArena
// repository's publish workflow puts them and the site - behind the X-Api-Key header, which has
// to be the secret ARENA_INGEST_KEY. Without that secret set, nothing gets in.
//
// The JSON the read routes answer with is written from the stored rows as they are, in the
// shapes of the files in site/data/, so anything that read those files reads these.

using System.Security.Cryptography;

using GenHTTP.Api.Content.Authentication;

/// <summary>Who an accepted ingest key belongs to.</summary>
public sealed record Publisher(string DisplayName, string[] Roles) : IUser;

public static class Api
{
    private static readonly ContentType JsonType = new("application/json; charset=utf-8");

    private static readonly Publisher Workflow = new("httparena-publish", []);

    public static IHandlerBuilder Create(ArenaStore store, SiteStore site)
    {
        var key = ApiKeyAuthentication.Create()
                                      .WithHeader("X-Api-Key")
                                      .Authenticator((_, given) => ValueTask.FromResult<IUser>(Accepts(given) ? Workflow : null));

        var ingest = Inline.Create()
                           .Post("publish", (Snapshot snapshot) => store.Publish(snapshot))
                           .Get("site", () => site.Manifest())
                           .Put("site/:sha256", (string sha256, Stream body) => site.PutAsync(sha256, body))
                           .Post("site", (SiteUpload upload) => site.Publish(upload))
                           .Authentication(key);

        var read = Inline.Create()
                         .Get("frameworks", (IRequest request) => Send(request, store.FrameworksJson()))
                         .Get("results", (IRequest request) => Send(request, store.ResultsJson()))
                         .Get("results/:slug", (IRequest request, string slug) => Send(request, Names.IsSlug(slug) ? store.ResultsJson(slug) : null))
                         .Get("host", (IRequest request) => Send(request, store.HostJson()))
                         .Get("site", () => site.Status())
                         .Get("publishes", (int? limit) => store.Publishes(limit ?? 20))
                         .Get("history/:slug/:key", (IRequest request, string slug, string key) => Send(request, store.HistoryJson(slug, key)));

        return Layout.Create()
                     .Add("ingest", ingest)
                     .Add(read);
    }

    private static IResponseBuilder Send(IRequest request, string json)
    {
        if (json == null)
        {
            throw new ProviderException(ResponseStatus.NotFound, "There is nothing published under that name.");
        }

        return request.Respond().Content(json, JsonType);
    }

    /// <summary>Whether the key is ARENA_INGEST_KEY, compared in constant time.</summary>
    private static bool Accepts(string given)
    {
        // read per request, so that a new key takes effect without a deploy
        if (string.IsNullOrEmpty(given) || !Secret.Exists("ARENA_INGEST_KEY"))
        {
            return false;
        }

        var expected = SHA256.HashData(Encoding.UTF8.GetBytes(Secret.Read("ARENA_INGEST_KEY")));

        return CryptographicOperations.FixedTimeEquals(expected, SHA256.HashData(Encoding.UTF8.GetBytes(given)));
    }
}
