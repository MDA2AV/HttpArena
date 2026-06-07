// ReSharper disable always CheckNamespace
// ReSharper disable always SuggestVarOrType_BuiltInTypes
// (var is avoided intentionally in this project so that concrete types are visible at call sites.)
// ReSharper disable always StackAllocInsideLoop
// ReSharper disable always ClassCannotBeInstantiated
#pragma warning disable CA2014

namespace Shrike;

public sealed partial class ShrikeEngine
{
    /// <summary>
    /// Factory for configuring and constructing an <see cref="ShrikeEngine"/>.
    /// Usage:
    /// <code>
    /// var engine = ShrikeEngine.CreateBuilder()
    ///     .SetPort(8080)
    ///     .SetBacklog(16384)
    ///     .SetMaxNumberConnectionsPerWorker(512)
    ///     .SetSlabSizes(16 * 1024, 16 * 1024)
    ///     .SetMaxEventsPerWake(512)
    ///     .SetMaxStackSizePerThread(1024 * 1024)
    ///     .SetNWorkersSolver(() => Environment.ProcessorCount / 2)
    ///     .InjectRequestHandler(conn => { /* write response */ })
    ///     .Build();
    /// </code>
    /// </summary>
    public static ShrikeBuilder CreateBuilder() => new ShrikeBuilder();

    // ===== Engine-wide configuration (static for now; set via builder) =====
    private static int _port = 8080;
    private static int _backlog = 16384;
    private static int _maxNumberConnectionsPerWorker = 512;
    private static int _inSlabSize = 16 * 1024;
    private static int _outSlabSize = 16 * 1024;
    private static int _maxEventsPerWake  = 512;
    private static int _maxStackSizePerThread  = 1024 * 1024;
    private static int _nWorkers;
    
    private static Func<int>? _calculateNumberWorkers;

    // Default per-connection handler loop (overridden via builder). Demonstrates the
    // Minima-style model: await ReadAsync, parse + write, await FlushAsync.
    private static Func<Connection, Task> _sHandler = DefaultHandler;

    private static async Task DefaultHandler(Connection conn)
    {
        while (true)
        {
            if (await conn.ReadAsync()) return;   // wait for data; true => peer closed
            bool wrote = false;
            while (conn.TryReadRequest())
            {
                conn.WriteBuffer.WriteUnmanaged("HTTP/1.1 200 OK\r\n"u8 +
                                                "Server: S\r\n"u8 +
                                                "Content-Type: text/plain\r\n"u8 +
                                                "Content-Length: 28\r\n\r\n"u8 +
                                                "Request handler was not set!"u8);
                conn.Clear();
                wrote = true;
            }
            if (wrote) await conn.FlushAsync();
        }
    }
    
    private ShrikeEngine() { }
    
    /// <summary>
    /// Fluent builder for <see cref="ShrikeEngine"/>. This configures static fields,
    /// then <see cref="Build"/> finalizes OS resources (listen socket) and decides worker count.
    /// </summary>
    public sealed class ShrikeBuilder
    {
        private readonly ShrikeEngine _engine;
        public ShrikeBuilder() => _engine = new ShrikeEngine();

        /// <summary>Set the TCP listening port (default: 8080).</summary>
        public ShrikeBuilder SetPort(int port)
        {
            _port = port;
            return this;
        }

        /// <summary>
        /// Set the listen backlog (default: 16384). This is a hint to the kernel for
        /// the maximum pending connection queue length.
        /// </summary>
        public ShrikeBuilder SetBacklog(int backlog)
        {
            _backlog = backlog;
            return this;
        }

        /// <summary>
        /// Max concurrent connections each worker is allowed to track (default: 512).
        /// Used for per-worker capacity planning and slab sizing.
        /// </summary>
        public ShrikeBuilder SetMaxNumberConnectionsPerWorker(int maxNumberConnectionsPerWorker)
        {
            _maxNumberConnectionsPerWorker = maxNumberConnectionsPerWorker;
            return this;
        }

        /// <summary>
        /// Configure input/output slab sizes used by connections (defaults: 16 KiB each).
        /// </summary>
        public ShrikeBuilder SetSlabSizes(int inSlabSize, int outSlabSize)
        {
            _inSlabSize = inSlabSize;
            _outSlabSize = outSlabSize;
            return this;
        }

        /// <summary>
        /// Operational batch size for epoll wait loops—how many events to pull per wake (default: 512).
        /// Increase if workers often see saturated event bursts.
        /// </summary>
        public ShrikeBuilder SetMaxEventsPerWake(int maxEventsPerWake)
        {
            _maxEventsPerWake = maxEventsPerWake;
            return this;
        }

        /// <summary>
        /// Max stack size per worker thread (default: 1 MiB). Useful when using large stackallocs
        /// in hot loops; keep conservative to avoid stack overflows under deep recursion or bursts.
        /// </summary>
        public ShrikeBuilder SetMaxStackSizePerThread(int maxStackSizePerThread)
        {
            _maxStackSizePerThread = maxStackSizePerThread;
            return this;
        }

        /// <summary>
        /// Provide a delegate that decides the worker count at build time.
        /// If not provided, defaults to <c>Environment.ProcessorCount / 2</c>.
        /// </summary>
        public ShrikeBuilder SetNWorkersSolver(Func<int>? solver)
        {
            _calculateNumberWorkers = solver;
            return this;
        }

        /// <summary>
        /// Inject the per-connection handler loop. It owns the request lifecycle:
        /// <c>await conn.ReadAsync()</c> → <c>while (conn.TryReadRequest()) { write }</c> → <c>await conn.FlushAsync()</c>.
        /// </summary>
        public ShrikeBuilder InjectHandler(Func<Connection, Task> handler)
        {
            _sHandler = handler;
            return this;
        }

        /// <summary>
        /// Finalize configuration:
        ///   - Logs arch and epoll_event packing
        ///   - Creates and configures the listening socket
        ///   - Resolves worker count via solver or default heuristic
        /// </summary>
        public ShrikeEngine Build()
        {
            Console.WriteLine(
                $"Arch={RuntimeInformation.ProcessArchitecture}, Packed={(Packed ? 12 : 16)}-byte epoll_event");

            // Decide worker count (solver wins if supplied).
            _nWorkers = _calculateNumberWorkers is null
                ? Environment.ProcessorCount / 2
                : _calculateNumberWorkers();

            return _engine;
        }
    }
    
}