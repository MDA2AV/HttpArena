public static class Project
{
    // Workspace, Resources, Secret and Database come from Platform/, for every file

    public static async Task<IHandler> CreateAsync() => Platform.Handlers.From(await BuildAsync());

    private static async Task<object> BuildAsync()
    {
        // HttpArena's site, and the results and logs behind it. None of it is edited here: the
        // HttpArena repository publishes all three when a pull request merges, through
        // scripts/publish_genhttp.py - the site as a new version of this lambda, the results
        // and the logs through api/ingest/.
        //
        //   GET    /, docs/, frameworks/, badge/, ...         the site, at the root of resources/
        //   GET    logs/{profile}/{conns}/{name}.log          a run's container log
        //
        //   GET    api/frameworks                             every entry, as site/data/frameworks.json
        //   GET    api/results                                every entry's results, by slug
        //   GET    api/results/{slug}                         one entry's, as site/data/results/{slug}.json
        //   GET    api/host                                   the benchmark machine, as of the newest publish
        //   GET    api/publishes?limit=20                     what was published, newest first
        //   GET    api/history/{slug}/{key}                   one result through every publish that changed it
        //
        //   POST   api/ingest/publish                         site/data at a commit of main  \
        //   GET    api/ingest/logs                            the logs kept, with hashes      | X-Api-Key:
        //   PUT    api/ingest/logs/{profile}/{conns}/{name}   one log, gzipped                | ARENA_INGEST_KEY
        //   DELETE api/ingest/logs/{profile}/{conns}/{name}                                  /
        //
        // The files: Store.cs keeps the records, Logs.cs the logs, Api.cs answers api/, Site.cs
        // serves the site; resources/migrations/ makes the tables; docs/ and tests/ say why and how.

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

        return Layout.Create()
                     .Add("api", Api.Create(store, logs))
                     .Add("logs", logs.Serve())
                     .Add(Site.Create());
    }
}
