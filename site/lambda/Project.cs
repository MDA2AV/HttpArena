public static class Project
{
    // Workspace, Resources, Secret and Database come from Platform/, for every file

    public static async Task<IHandler> CreateAsync() => Platform.Handlers.From(await BuildAsync());

    private static async Task<object> BuildAsync()
    {
        // HttpArena's site, and the results behind it. Neither is edited here: the HttpArena
        // repository holds them, and publishes both through api/ingest/ when its "Publish to
        // genhttp.dev" workflow is run (scripts/publish_genhttp.py), as data - a new version of
        // this lambda is saved only when its code in the repository's site/lambda/ changed. The
        // runs' logs stay in the repository, and the site's links to them are sent on there.
        //
        //   GET    /, docs/, frameworks/, badge/, ...         the site, as published last
        //   GET    logs/{profile}/{conns}/{name}.log          302 to the run's log in the repository
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
        //   GET    api/ingest/site                            the site's paths, and the       | X-Api-Key:
        //                                                     content kept, by SHA-256        | ARENA_INGEST_KEY
        //   PUT    api/ingest/site/{sha256}                   one file's content              |
        //   POST   api/ingest/site                            every path at a commit of main  /
        //
        // The files: Store.cs keeps the records and Site.cs the site, Api.cs answers api/ and
        // Logs.cs logs/; resources/migrations/ makes the tables; docs/ and tests/ say why and how.

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

        Workspace.CreateFolder("site");

        var site = new SiteStore(new SiteFolder(Workspace.Tree("site"), Workspace.List, Workspace.Exists, Workspace.WriteBytes, Workspace.Delete));

        return Layout.Create()
                     .Add("api", Api.Create(store, site))
                     .Add("logs", Logs.Serve())
                     .Add(site.Serve());
    }
}
