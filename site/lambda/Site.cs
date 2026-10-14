// The site: what scripts/gen_leaderboard_data.py generated and scripts/assemble_site.sh laid out
// at a commit of main - the tree GitHub Pages serves, without the logs. It is data, like the
// results beside it: the HttpArena repository sends it through api/ingest/site/ when its publish
// workflow is run, no version is saved for it, and a deploy leaves it as it is.
//
// The workspace keeps every file under site/{sha256 of its content}, and the site_files table
// says which content each path is. A publish first sends the content the workspace does not
// have, then every path at once, so the site moves from one commit to the next in one step and
// a file two publishes have in common is sent and kept once. Content named neither by the new
// paths nor by the ones before them is deleted then: a page still being sent while the site
// changes finds its file.
//
// A folder answers with its index.html (docs/scoring/ is docs/scoring/index.html), a folder
// asked for without its slash is sent on to it as GitHub Pages does, and a path that is nothing
// answers 404 with the site's own 404.html.

using System.Security.Cryptography;

/// <summary>What the site store may do with the workspace: read its site/ folder, and keep files there.</summary>
public record SiteFolder(IResourceContainer Content, Func<string[]> List, Func<string, bool> Exists, Action<string, byte[]> Write, Action<string> Delete);

/// <summary>What a publish sends once the content is there: every path of the site, with the SHA-256 of what it holds.</summary>
public record SiteUpload(string Commit, Dictionary<string, string> Files);

/// <summary>The site as it is served, and the content the workspace keeps - what an upload compares against.</summary>
public record SiteManifest(string Commit, DateTime? Published, Dictionary<string, string> Files, string[] Kept);

/// <summary>Which commit's site is online, null before the first publish.</summary>
public record SiteStatus(string Commit, DateTime? Published, int Files);

public record SiteContentInfo(string Sha256, long Bytes);

/// <summary>What a publish did. Unchanged: the site already was exactly this.</summary>
public record SitePublishSummary(long Id, string Commit, int Files, int Changed, int Removed, int Deleted, bool Unchanged);

public sealed class SiteStore
{
    // the biggest file of the site, data.js, is about 1 MB
    private const int MaxContent = 32 * 1024 * 1024;

    private const int MaxFiles = 50_000;

    private const string Prefix = "site/";

    private static readonly ContentType Unknown = new("application/octet-stream");

    private readonly Lock _gate = new();

    private readonly SiteFolder _folder;

    // replaced whole by a publish and never changed, so a request reads it without the gate
    private volatile Served _served;

    private sealed record Served(string Commit, DateTime? Published, Dictionary<string, Entry> Files);

    private sealed record Entry(string Sha256, ContentType Type);

    public SiteStore(SiteFolder folder)
    {
        _folder = folder;
        _served = Load();
    }

    public bool Published => _served.Commit != null;

    public bool Has(string path) => _served.Files.ContainsKey(path);

    /// <summary>The file served at a path, null where the site has none.</summary>
    public async ValueTask<(IResource Resource, ContentType Type)?> OpenAsync(string path)
    {
        if (!_served.Files.TryGetValue(path, out var entry))
        {
            return null;
        }

        var resource = await _folder.Content.TryGetResourceAsync(new PathSegment(entry.Sha256));

        return resource != null ? (resource, entry.Type) : null;
    }

    public SiteStatus Status()
    {
        var served = _served;

        return new SiteStatus(served.Commit, served.Published, served.Files.Count);
    }

    public SiteManifest Manifest()
    {
        var served = _served;

        var kept = _folder.List()
                          .Where(name => name.StartsWith(Prefix, StringComparison.Ordinal))
                          .Select(name => name[Prefix.Length..])
                          .Where(Names.IsSha256)
                          .Order(StringComparer.Ordinal)
                          .ToArray();

        return new SiteManifest(served.Commit, served.Published, served.Files.ToDictionary(f => f.Key, f => f.Value.Sha256), kept);
    }

    /// <summary>PUT site/{sha256}: one file's content, kept once whatever paths it is served at.</summary>
    public async Task<SiteContentInfo> PutAsync(string sha256, Stream body)
    {
        if (!Names.IsSha256(sha256))
        {
            throw new ProviderException(ResponseStatus.BadRequest, "Content is put at the SHA-256 of what it holds, in lower case hex.");
        }

        // the body comes over the network; the rest is memory and the workspace
        var content = await ReadAsync(body);

        var actual = Convert.ToHexString(SHA256.HashData(content)).ToLowerInvariant();

        if (actual != sha256)
        {
            throw new ProviderException(ResponseStatus.BadRequest, $"What was sent has the SHA-256 {actual}, not {sha256}.");
        }

        lock (_gate)
        {
            if (!_folder.Exists(Blob(sha256)))
            {
                _folder.Write(Blob(sha256), content);
            }
        }

        return new SiteContentInfo(sha256, content.Length);
    }

    /// <summary>POST site: every path of the site at a commit, which replaces the paths served until now.</summary>
    public SitePublishSummary Publish(SiteUpload upload)
    {
        Validate(upload);

        lock (_gate)
        {
            if (upload.Files.Values.Distinct().Any(sha256 => !_folder.Exists(Blob(sha256))))
            {
                // never sent, or gone since: the publish sends what is not kept and asks again
                throw new ProviderException(ResponseStatus.Conflict, "The workspace does not keep all of this content yet: send what GET api/ingest/site does not list as kept, then publish again.");
            }

            using var db = new ArenaContext(Database.GetConnection());

            using var transaction = db.Database.BeginTransaction();

            var current = db.SiteFiles.ToDictionary(f => f.Path);

            var before = current.Values.Select(f => f.Sha256).ToHashSet();

            var changed = 0;

            foreach (var (path, sha256) in upload.Files)
            {
                if (current.Remove(path, out var entry))
                {
                    if (entry.Sha256 == sha256)
                    {
                        continue;
                    }

                    entry.Sha256 = sha256;
                }
                else
                {
                    db.SiteFiles.Add(new SiteFileEntry { Path = path, Sha256 = sha256 });
                }

                changed++;
            }

            // what is left was served until now and is not part of this site
            var removed = current.Count;

            db.SiteFiles.RemoveRange(current.Values);

            var last = db.SitePublishes.AsNoTracking().OrderByDescending(p => p.Id).FirstOrDefault();

            if (changed == 0 && removed == 0 && last != null)
            {
                transaction.Rollback();

                return new SitePublishSummary(last.Id, last.Commit, upload.Files.Count, 0, 0, 0, Unchanged: true);
            }

            var publish = new SitePublishEntry
            {
                Created = DateTime.UtcNow,
                Commit = upload.Commit,
                Files = upload.Files.Count,
                Changed = changed,
                Removed = removed
            };

            db.SitePublishes.Add(publish);
            db.SaveChanges();

            transaction.Commit();

            _served = new Served(publish.Commit, publish.Created, upload.Files.ToDictionary(f => f.Key, f => new Entry(f.Value, TypeOf(f.Key))));

            var keep = upload.Files.Values.ToHashSet();

            keep.UnionWith(before);

            var deleted = 0;

            foreach (var name in _folder.List())
            {
                if (name.StartsWith(Prefix, StringComparison.Ordinal) && !keep.Contains(name[Prefix.Length..]))
                {
                    _folder.Delete(name);
                    deleted++;
                }
            }

            return new SitePublishSummary(publish.Id, publish.Commit, publish.Files, changed, removed, deleted, Unchanged: false);
        }
    }

    /// <summary>The site, as the handler at the root of the lambda.</summary>
    public IHandler Serve() => new SiteHandler(this);

    private static Served Load()
    {
        using var db = new ArenaContext(Database.GetConnection());

        var last = db.SitePublishes.AsNoTracking().OrderByDescending(p => p.Id).FirstOrDefault();

        var files = db.SiteFiles.AsNoTracking().ToDictionary(f => f.Path, f => new Entry(f.Sha256, TypeOf(f.Path)));

        return new Served(last?.Commit, last?.Created, files);
    }

    private static ContentType TypeOf(string path) => path.GuessContentType() ?? Unknown;

    private static string Blob(string sha256) => Prefix + sha256;

    private static void Validate(SiteUpload upload)
    {
        if (upload?.Files == null)
        {
            throw new ProviderException(ResponseStatus.BadRequest, "Send the site as JSON: {commit, files: {path: sha256}}.");
        }

        if (upload.Commit is not { Length: >= 7 and <= 40 } commit || !commit.All(Uri.IsHexDigit))
        {
            throw new ProviderException(ResponseStatus.BadRequest, "commit is the hex SHA of the commit the site was generated at.");
        }

        if (upload.Files.Count > MaxFiles || !upload.Files.ContainsKey("index.html"))
        {
            throw new ProviderException(ResponseStatus.BadRequest, $"A site has an index.html, and at most {MaxFiles} files.");
        }

        foreach (var (path, sha256) in upload.Files)
        {
            if (!Names.IsSitePath(path))
            {
                throw new ProviderException(ResponseStatus.BadRequest, $"{path} is not a path of the site: folders and a name of [A-Za-z0-9._-], none starting with a dot.");
            }

            if (!Names.IsSha256(sha256))
            {
                throw new ProviderException(ResponseStatus.BadRequest, $"{path} names {sha256}, which is not a SHA-256 in lower case hex.");
            }
        }
    }

    /// <summary>Reads the body, but never more than the limit.</summary>
    private static async Task<byte[]> ReadAsync(Stream body)
    {
        using var buffer = new MemoryStream();

        var chunk = new byte[64 * 1024];

        int read;

        while ((read = await body.ReadAsync(chunk)) > 0)
        {
            if (buffer.Length + read > MaxContent)
            {
                throw new ProviderException(ResponseStatus.RequestEntityTooLarge, $"A file of the site can be {MaxContent / 1024 / 1024} MB at most.");
            }

            buffer.Write(chunk, 0, read);
        }

        return buffer.ToArray();
    }
}

/// <summary>Answers a path of the site the way GitHub Pages does.</summary>
public sealed class SiteHandler(SiteStore site) : IHandler
{
    private static readonly ContentType Html = new("text/html; charset=utf-8");

    private static readonly ContentType Text = new("text/plain; charset=utf-8");

    public ValueTask PrepareAsync(IServer server) => ValueTask.CompletedTask;

    public async ValueTask<IResponse> HandleAsync(IRequest request)
    {
        if (!request.HasType(RequestMethod.Get, RequestMethod.Head))
        {
            return request.Respond().Status(ResponseStatus.MethodNotAllowed).Header("Allow", "GET, HEAD").Build();
        }

        var target = request.Header.Target;

        var path = target.AsString(remainingOnly: true).Trim('/');

        var name = path.Length == 0 ? "index.html" : target.HasTrailingSlash ? path + "/index.html" : path;

        if (await site.OpenAsync(name) is (var resource, var type))
        {
            return request.Respond().Content(resource, type).Build();
        }

        if (!site.Published)
        {
            return request.Respond()
                          .Status(ResponseStatus.ServiceUnavailable)
                          .Content("The site was not published here yet: the HttpArena repository sends it with scripts/publish_genhttp.py.", Text)
                          .Build();
        }

        if (path.Length > 0 && !target.HasTrailingSlash && site.Has(path + "/index.html"))
        {
            // relative, as every address here is: "scoring/" from docs/scoring
            return request.Respond()
                          .Status(ResponseStatus.MovedPermanently)
                          .Header("Location", path[(path.LastIndexOf('/') + 1)..] + "/")
                          .Build();
        }

        var notFound = request.Respond().Status(ResponseStatus.NotFound);

        return (await site.OpenAsync("404.html") is (var page, _) ? notFound.Content(page, Html) : notFound.Content("Not found.", Text)).Build();
    }
}
