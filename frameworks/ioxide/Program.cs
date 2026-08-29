using System.Runtime.InteropServices;

using ioxide;
using ioxide.file;
using ioxide.nghttp3;
using ioxide.pg;
using ioxide.tls;
using ioxide.utils;

namespace IoxideArena;

/// <summary>
/// ioxide - the ioxide runtime (consumed as its published NuGet packages) serving the arena
/// profiles. The engine is untouched; the HTTP/1.1 handler (request line, headers, Content-Length
/// + chunked bodies, keep-alive, pipelining, fragmented reads) is hand-written on the raw
/// recv/send API. No HTTP framework.
///
/// Endpoints:
///   GET/POST /baseline11?a=&amp;b=        -> text/plain "a + b (+ body)"
///   GET      /pipeline                    -> text/plain "ok"
///   GET      /json/{count}?m=N            -> application/json, total = price*quantity*N
///   GET      /static/{file}               -> asset read off the ring (ioxide.file)
///   GET      /delay/{ms}                  -> text/plain "{ms}", waited on the ring (ioxide.timer)
///   POST     /echo                        -> the request body, unchanged
///   GET      /async-db?min=&amp;max=&amp;limit= -> Postgres seq scan via ioxide.pg (SCRAM-SHA-256)
///
/// Configuration is entirely environmental (IOXIDE_*, plus DATABASE_URL and TLS_CERT/TLS_KEY from
/// the harness) - see <see cref="Config"/>, which holds the whole surface and the reasoning for
/// the few values this entry pins itself.
/// </summary>
internal static class Program
{
    // Held for the process lifetime so the registrations aren't garbage-collected.
    private static PosixSignalRegistration? _sigTerm;
    private static PosixSignalRegistration? _sigInt;

    private static int Main()
    {
        InstallSignalHandlers();

        using var config = Config.FromEnvironment();

        var dataset = Dataset.Load(config.DatasetPath);

        // Static assets: every file under the root opened ONCE, descriptors shared across reactors
        // and read positionally off the ring. Nothing is cached in memory and no HTTP is baked -
        // the response header is framed in HttpSession and the body is read straight into the
        // connection's write slab, so header and body leave in one flush with no copy.
        bool hasStatic = Directory.Exists(config.StaticRoot);
        StaticAssets? assets = hasStatic ? new StaticAssets(config.StaticRoot) : null;
        // Precompressed variants are baked here (HTTP), not in ioxide.file.
        Precompressed? precompressed = hasStatic ? new Precompressed(config.StaticRoot) : null;
        // Both caches above are built once and would otherwise never look at the directory again;
        // this is what makes them follow it.
        StaticRefresh.Init(config.StaticRoot, assets, precompressed);

        config.Describe(dataset.Count, assets?.Count ?? 0, precompressed?.Count ?? 0);

        Multiplexed.Init(hasStatic ? config.StaticRoot : null);
        Handler.Init(config, dataset, assets, precompressed);

        RunReactors(config);
        return 0;
    }

    /// <summary>
    /// Exit promptly on `docker stop` (SIGTERM) instead of lingering until SIGKILL. The bench
    /// harness restarts the framework per profile but keeps ONE Postgres for the whole run, so a
    /// slow teardown leaves this server's ~PoolSize*reactors backends occupying connection slots
    /// while the next profile's server eagerly opens its own pool against the same Postgres.
    /// Exiting at once closes our sockets so Postgres reaps those backends before the handoff.
    /// </summary>
    private static void InstallSignalHandlers()
    {
        _sigTerm = PosixSignalRegistration.Create(PosixSignal.SIGTERM, ctx => { ctx.Cancel = true; Environment.Exit(0); });
        _sigInt  = PosixSignalRegistration.Create(PosixSignal.SIGINT,  ctx => { ctx.Cancel = true; Environment.Exit(0); });
    }

    /// <summary>
    /// One reactor per thread, each owning its ring and its share of the SO_REUSEPORT listeners.
    /// Services start from OnStart so they are constructed on the reactor thread that will use
    /// them - shared-nothing means a pool built out here would be the wrong reactor's.
    /// </summary>
    private static void RunReactors(Config config)
    {
        var threads = new Thread[config.Server.ReactorCount];

        for (int i = 0; i < threads.Length; i++)
        {
            var reactor = new Reactor(i, config.Server);

            reactor.OnStart = r =>
            {
                if (config.Pg != null)
                {
                    PgPool.Start(r, config.Pg);
                }

                if (config.Tls)
                {
                    // h1 takes the reactor's registered TlsService; h2 is held beside it in H2Tls
                    // because a reactor holds one service per type and these two differ only by
                    // the ALPN list they offer.
                    TlsService.Start(r, config.H1TlsOptions!);
                    r.AddService(new H2Tls(TlsService.Start(r, config.H2TlsOptions!, register: false)));
                }
            };

            reactor.TcpHandle = Handler.HandleAsync;
            if (config.Server.Quic != null)
            {
                reactor.QuicHandle = (_, qc) =>
                    new Nghttp3Connection(qc, config.Http3).RunBufferedAsync(Multiplexed.RouteH3);
            }

            threads[i] = new Thread(reactor.Run) { Name = $"reactor-{i}", IsBackground = false };
            threads[i].Start();
        }

        foreach (var t in threads)
        {
            t.Join();
        }
    }
}
