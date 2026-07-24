using System.Net;
using System.Runtime.InteropServices;
using ioxide;
using ioxide.utils;
using ioxide.pg;
using ioxide.file;
using ioxide.tls;
using ioxide.redis;
using StackExchange.Redis;
using Microsoft.Extensions.Caching.Memory;

namespace IoxideArena;

/// <summary>
/// ioxide - the ioxide runtime (consumed as its published NuGet packages) serving the H1
/// profiles. The engine is untouched; the HTTP/1.1 handler (request line, headers,
/// Content-Length + chunked bodies, keep-alive, pipelining, fragmented reads) is hand-written
/// on the raw recv/send API. No HTTP framework.
///
/// Endpoints:
///   GET/POST /baseline11?a=&amp;b=        -> text/plain "a + b (+ body)"
///   GET      /pipeline                    -> text/plain "ok"
///   GET      /json/{count}?m=N            -> application/json, total = price*quantity*N
///   GET      /static/{file}               -> baked asset snapshots (ioxide.file)
///   GET      /async-db?min=&amp;max=&amp;limit= -> Postgres seq scan via ioxide.pg (SCRAM-SHA-256)
/// </summary>
internal static class Program
{
    // Held for the process lifetime so the registrations aren't garbage-collected.
    private static PosixSignalRegistration? _sigTerm;
    private static PosixSignalRegistration? _sigInt;

    private static int Main()
    {
        // Exit promptly on `docker stop` (SIGTERM) instead of lingering until SIGKILL. The bench
        // harness restarts the framework per profile but keeps ONE Postgres for the whole run, so a
        // slow teardown leaves this server's ~PoolSize*reactors backends occupying connection slots
        // while the next profile's server eagerly opens its own pool against the same Postgres.
        // Exiting at once closes our sockets so Postgres reaps those backends before the handoff.
        _sigTerm = PosixSignalRegistration.Create(PosixSignal.SIGTERM, ctx => { ctx.Cancel = true; Environment.Exit(0); });
        _sigInt  = PosixSignalRegistration.Create(PosixSignal.SIGINT,  ctx => { ctx.Cancel = true; Environment.Exit(0); });

        // One reactor per core, capped at 64 so a hyperthreaded box (ProcessorCount counts logical
        // CPUs, e.g. 128 on 64 cores + SMT) doesn't oversubscribe. IOXIDE_REACTORS overrides.
        int reactors = Math.Min(Environment.ProcessorCount, 64);
        if (int.TryParse(Environment.GetEnvironmentVariable("IOXIDE_REACTORS"), out int r) && r > 0)
            reactors = r;
        Console.WriteLine($"[ioxide] ProcessorCount={Environment.ProcessorCount}, reactors={reactors}");

        ushort port = 8080;
        if (ushort.TryParse(Environment.GetEnvironmentVariable("IOXIDE_PORT"), out ushort p) && p > 0)
            port = p;

        // TLS on :8081 when the harness mounts certs (json-tls profile).
        string certPath = Environment.GetEnvironmentVariable("TLS_CERT") ?? "/certs/server.crt";
        string keyPath = Environment.GetEnvironmentVariable("TLS_KEY") ?? "/certs/server.key";
        bool tls = File.Exists(certPath) && File.Exists(keyPath);

        // Recv buffer ring, env-tunable: the upload profile moves large bodies, so each recv slice is
        // capped at the buffer size - bigger buffers mean far fewer slices (CQEs + returns) for the
        // same bytes. recvKb * ringEntries is the reserved recv memory per reactor.
        int recvKb = int.TryParse(Environment.GetEnvironmentVariable("IOXIDE_RECV_KB"), out int rk) && rk > 0 ? rk : 16;
        int ringEntries = int.TryParse(Environment.GetEnvironmentVariable("IOXIDE_RING_ENTRIES"), out int re) && re > 0 ? re : 256;

        var config = new ServerConfig
        {
            Port              = port,
            ExtraPorts        = tls ? [(ushort)8081] : [],
            ReactorCount      = reactors,
            Incremental       = false,
            RecvBufferSize    = recvKb * 1024,
            BufferRingEntries = ringEntries,
            // 128 KB so a static response fits one slab and the handler sends it without chunk-flushing.
            WriteSlabSize     = 128 * 1024,
        };

        var dsPath = Environment.GetEnvironmentVariable("IOXIDE_DATASET") ?? "/data/dataset.json";
        var dataset = Dataset.Load(dsPath);

        // Static assets: baked snapshots (full response precomputed per file).
        var staticRoot = Environment.GetEnvironmentVariable("IOXIDE_STATIC") ?? "/data/static";
        // Bake every file (largest is ~300 KB vendor.js; default threshold is 256 KB).
        StaticAssets? assets = Directory.Exists(staticRoot)
            ? new StaticAssets(staticRoot, maxCachedFileBytes: 1 << 20)
            : null;
        // Precompressed variants are baked here (HTTP), not in ioxide.file.
        Precompressed? precompressed = Directory.Exists(staticRoot) ? new Precompressed(staticRoot) : null;

        // Postgres: DATABASE_URL=postgres://user:pass@host:port/db (validation/benchmark sidecar).
        PgOptions? pg = null;
        var dbUrl = Environment.GetEnvironmentVariable("DATABASE_URL");
        if (!string.IsNullOrEmpty(dbUrl))
        {
            var uri = new Uri(dbUrl);
            string[] userInfo = uri.UserInfo.Split(':', 2);
            int maxConn = int.TryParse(Environment.GetEnvironmentVariable("DATABASE_MAX_CONN"), out int mc) ? mc : 256;

            pg = new PgOptions
            {
                Host = ResolveIPv4(uri.Host),
                Port = (ushort)(uri.Port > 0 ? uri.Port : 5432),
                User = userInfo[0],
                Password = userInfo.Length > 1 ? userInfo[1] : null,
                Database = uri.AbsolutePath.TrimStart('/'),
                PoolSize = Math.Clamp(maxConn / reactors, 1, 8),
            };
        }

        // Redis: REDIS_URL=redis://host:port (crud cache-aside sidecar).
        RedisOptions? redis = null;
        var redisUrl = Environment.GetEnvironmentVariable("REDIS_URL");
        if (!string.IsNullOrEmpty(redisUrl))
        {
            var uri = new Uri(redisUrl);
            redis = new RedisOptions
            {
                Host = ResolveIPv4(uri.Host),
                Port = (ushort)(uri.Port > 0 ? uri.Port : 6379),
                PoolSize = 4,
            };
        }

        // Crud cache backend (CRUD_CACHE): inproc (default) = one shared IMemoryCache, fully
        // in-process and inline on the reactor (no network, no thread pool); ioxide = ioxide.redis
        // (per-reactor, pipelined, on the ring); stackexchange = StackExchange.Redis (one shared
        // multiplexer, off-ring). The Redis backends need REDIS_URL; without it they fall back to inproc.
        string cacheBackend = Environment.GetEnvironmentVariable("CRUD_CACHE") ?? "inproc";
        if ((cacheBackend == "ioxide" || cacheBackend == "stackexchange") && redis == null)
        {
            cacheBackend = "inproc";
        }
        IMemoryCache? memCache = cacheBackend == "inproc" ? new MemoryCache(new MemoryCacheOptions()) : null;
        ConnectionMultiplexer? mux = cacheBackend == "stackexchange"
            ? ConnectionMultiplexer.Connect($"{redis!.Host}:{redis.Port}")
            : null;

        Console.WriteLine($"[ioxide] {config.ReactorCount} reactors on :{config.Port} " +
                          $"(dataset={dataset.Count} items, static={(assets?.Count ?? 0)} files ({(precompressed?.Count ?? 0)} precompressed), " +
                          $"pg={(pg != null ? $"{pg.Host}:{pg.Port}/{pg.Database} pool={pg.PoolSize}" : "off")}, " +
                          $"tls={(tls ? "8081 (ktls tx)" : "off")}, " +
                          $"cache={(pg != null ? cacheBackend : "off")})");

        Handler.Init(config, dataset, assets, precompressed, pg != null, tls, pg != null);

        var threads = new Thread[config.ReactorCount];
        for (int i = 0; i < config.ReactorCount; i++)
        {
            var reactor = new Reactor(i, config);
            var pgOptions = pg;
            var redisOptions = redis;
            
            reactor.OnStart = reactorInstance =>
            {
                if (pgOptions != null)
                {
                    PgPool.Start(reactorInstance, pgOptions);
                    
                    // Crud cache, shared across reactors (inproc/stackexchange) or per-reactor (ioxide).
                    ICrudCache cache = cacheBackend switch
                    {
                        "ioxide"        => new IoxideRedisCache(RedisPool.Start(reactorInstance, redisOptions!)),
                        "stackexchange" => new StackExchangeCache(mux!.GetDatabase()),
                        _               => new InProcCache(memCache!),
                    };
                    reactorInstance.AddService<ICrudCache>(cache);
                }
                if (tls)
                {
                    TlsService.Start(reactorInstance, new TlsOptions { CertificatePath = certPath, KeyPath = keyPath });
                }
            };
            
            reactor.Handle = Handler.HandleAsync;
            threads[i] = new Thread(reactor.Run) { Name = $"reactor-{i}", IsBackground = false };
            threads[i].Start();
        }
        foreach (var t in threads)
        {
            t.Join();
        }
        
        return 0;
    }

    // RingSocket dials IPv4 literals; resolve names (e.g. "localhost") once, at startup.
    private static string ResolveIPv4(string host)
    {
        if (IPAddress.TryParse(host, out _)) return host;
        foreach (var addr in Dns.GetHostAddresses(host))
        {
            if (addr.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork)
            {
                return addr.ToString();
            }
        }
        
        return "127.0.0.1";
    }
}
