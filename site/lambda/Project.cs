public static class Project
{
    // Workspace, Resources, Secret and Database come from Platform/, for every file

    public static async Task<IHandler> CreateAsync() => Platform.Handlers.From(await BuildAsync());

    private static async Task<object> BuildAsync()
    {
        // HttpArena's site, and the results and logs behind it. None of it is edited here: the
        // HttpArena repository publishes all three through api/ingest/ when a pull request
        // merges (scripts/publish_genhttp.py), as data - a new version of this lambda is saved
        // only when its code in the repository's site/lambda/ changed.
        //
        //   GET    /, docs/, frameworks/, badge/, ...         the site, as published last
        //   GET    logs/{profile}/{conns}/{name}.log          a run's container log
        //
        //   GET    api/frameworks                             every entry, as site/data/frameworks.json
        //   GET    api/results                                every entry's results, by slug
        //   GET    api/results/{slug}                         one entry's, as site/data/results/{slug}.json
        //   GET    api/host                                   the benchmark machine, as of the newest publish
        //   GET    api/publishes?limit=20                     what was published, newest first
        //   GET    api/history/{slug}/{key}                   one result through every publish that changed it
        //   GET    api/site                                   which commit's site is online
        //
        //   POST   api/ingest/publish                         site/data at a commit of main   \
        //   GET    api/ingest/site                            the site's paths, and the       |
        //                                                     content kept, by SHA-256        |
        //   PUT    api/ingest/site/{sha256}                   one file's content              | X-Api-Key:
        //   POST   api/ingest/site                            every path at a commit of main  | ARENA_INGEST_KEY
        //   GET    api/ingest/logs                            the logs kept, with hashes      |
        //   PUT    api/ingest/logs/{profile}/{conns}/{name}   one log, gzipped                |
        //   DELETE api/ingest/logs/{profile}/{conns}/{name}                                   /
        //
        // The files: Store.cs keeps the records, Site.cs the site and Logs.cs the logs, Api.cs
        // answers api/; resources/migrations/ makes the tables; docs/ and tests/ say why and how.

        // every version reads the same database, so each brings it up to the schema it
        // expects first; Evolve applies what is new in resources/migrations/, once each
        using (var connection = Database.GetConnection())
        {
            new Evolve(connection, message => Console.WriteLine(message))
            {
                Locations = [Resources.Root + "migrations"],
                IsEraseDisabled = true
            }.Migrate();
        }

        var store = new ArenaStore();

        var logs = new LogStore(store, new LogFiles(Workspace.ReadBytes, Workspace.WriteBytes, Workspace.Delete, Workspace.Exists));

        Workspace.CreateFolder("site");

        var site = new SiteStore(new SiteFolder(Workspace.Tree("site"), Workspace.List, Workspace.Exists, Workspace.WriteBytes, Workspace.Delete));

        return Layout.Create()
                     .Add("api", Api.Create(store, logs, site))
                     .Add("logs", logs.Serve())
                     .Add(site.Serve());
    }
}
