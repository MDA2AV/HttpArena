using System.Net;

using ioxide;
using ioxide.http2;
using ioxide.nghttp3;
using ioxide.ngtcp2;
using ioxide.pg;
using ioxide.tls;

namespace IoxideArena;

/// <summary>
/// Everything the entry is configured with, read from IOXIDE_* once at startup.
///
/// Every knob ioxide exposes on the paths this entry uses is reachable from here - the engine, the
/// TCP listeners, the UDP sockets under QUIC, the QUIC endpoint, TLS, and the h2/h3 layers - and
/// each one falls back to the LIBRARY's own default, read off a throwaway instance rather than
/// copied into this file as a literal. That distinction matters for a benchmark entry: an unset
/// variable then means "whatever ioxide ships", so a default that moves in the library moves here
/// too instead of being silently pinned to a number nobody remembers writing.
///
/// The handful of values this entry deliberately differs on are marked; they are the only real
/// configuration decisions in the file.
/// </summary>
internal sealed class Config : IDisposable
{
    // ── what the request path needs ──────────────────────────────────────────────────────────
    public required bool Tls { get; init; }
    public required ushort TlsPort { get; init; }          // h1 over TLS (json-tls, static-tls)
    public required ushort H2Port { get; init; }           // h2 over TLS, and QUIC's UDP port
    public required string DatasetPath { get; init; }
    public required string StaticRoot { get; init; }

    // ── built for the reactors ───────────────────────────────────────────────────────────────
    public required ServerConfig Server { get; init; }
    public required TlsOptions? H1TlsOptions { get; init; }
    public required TlsOptions? H2TlsOptions { get; init; }
    public required Http2Options Http2 { get; init; }
    public required Nghttp3Options Http3 { get; init; }
    public required PgOptions? Pg { get; init; }
    public required QuicEngine? QuicEngine { get; init; }

    public void Dispose() => QuicEngine?.Dispose();

    public static Config FromEnvironment()
    {
        // The library defaults, read off throwaway instances. Options are init-only records, so
        // there is no way to ask "was this set?" after the fact - the fallback has to be in hand
        // before the object is built.
        var srvDefault  = new ServerConfig();
        var tcpDefault  = new TcpOptions();
        var udpDefault  = new UdpOptions();
        var quicDefault = new QuicOptions();
        var tlsDefault  = new TlsOptions();
        var h2Default   = new Http2Options();
        var h3Default   = new Nghttp3Options();
        var incDefault  = new IncrementalOptions();

        // One reactor per core, capped at 64 so a hyperthreaded box (ProcessorCount counts logical
        // CPUs, e.g. 128 on 64 cores + SMT) doesn't oversubscribe.
        int reactors = Env.Int("IOXIDE_REACTORS", Math.Min(Environment.ProcessorCount, 64));

        ushort port    = Env.Port("IOXIDE_PORT", 8080);
        ushort tlsPort = Env.Port("IOXIDE_TLS_PORT", 8081);
        ushort h2Port  = Env.Port("IOXIDE_H2_PORT", 8443);

        string certPath = Env.Str("TLS_CERT", "/certs/server.crt");
        string keyPath  = Env.Str("TLS_KEY", "/certs/server.key");
        bool tls = File.Exists(certPath) && File.Exists(keyPath);   // the harness mounts /certs

        // ── TLS ──────────────────────────────────────────────────────────────────────────────
        // kTLS TX is load-bearing here, not a tuning knob, and is the one thing on this page that
        // is deliberately NOT reachable from the environment.
        //
        // The h1 handler writes PLAINTEXT into the connection's write slab and lets the kernel
        // frame it - that is what lets a static file be read off the ring straight into the slab
        // behind its header and leave in one flush. Turn TX offload off and nothing encrypts: the
        // handshake still succeeds, ALPN still resolves, and then every response goes out in the
        // clear to a client expecting records (curl reports "wrong version number"). A knob whose
        // off position silently serves plaintext on a TLS port is worse than no knob.
        //
        // h2 would survive it - that path runs through TlsConnectionDualPipe, which encrypts in
        // userspace - but one TlsOptions backs both listeners, so this stays pinned for both.
        const bool kernelTx = true;

        // RX is a genuine knob: inbound is decrypted through the session either way, so turning
        // kernel receive off just moves that work to userspace. Worth having, because RX offload
        // is experimental (about one first connection in twelve fails the handoff).
        bool kernelRx = Env.Bool("IOXIDE_KTLS_RX", true);

        // Same certificate and backends on both TLS ports; ALPN is the whole difference, and it
        // is what decides which protocol a client gets. TlsOptions is a class rather than a
        // record, so the h2 variant is built rather than `with`-ed. Null Alpn keeps the library
        // default, ["http/1.1"], which is what the h1 port wants.
        TlsOptions BuildTls(string[]? alpn) => new()
        {
            CertificatePath    = certPath,
            KeyPath            = keyPath,
            KernelTx           = kernelTx,
            KernelRx           = kernelRx,
            Alpn               = alpn ?? tlsDefault.Alpn,
            HandshakeTimeoutMs = Env.Int("IOXIDE_TLS_HANDSHAKE_MS", tlsDefault.HandshakeTimeoutMs),
            MinProtocolVersion = Env.Enum("IOXIDE_TLS_MIN_VERSION", tlsDefault.MinProtocolVersion),
            CipherSuites       = Env.StrOrNull("IOXIDE_TLS_CIPHER_SUITES") ?? tlsDefault.CipherSuites,
            CipherList         = Env.StrOrNull("IOXIDE_TLS_CIPHER_LIST") ?? tlsDefault.CipherList,
        };

        TlsOptions? h1Tls = tls ? BuildTls(null) : null;
        TlsOptions? h2Tls = tls ? BuildTls(["h2"]) : null;

        // ── QUIC engine (per-endpoint QUIC/TLS state, shared by every connection) ─────────────
        uint cidLength = Env.UInt("IOXIDE_QUIC_CID_LEN", (uint)quicDefault.LocalCidLength);
        QuicEngine? quic = tls
            ? new QuicEngine(certPath, keyPath, cidLength, alpn: ["h3"],
                             // Per-connection send-retention high-water: a response larger than
                             // this streams out paced by the peer's acks instead of buffering
                             // whole, so memory stays ~this per connection whatever static-h3 is
                             // serving. 16 MiB is the library's own value, restated rather than
                             // read off an instance because it is a constructor argument.
                             maxSendRetentionBytes: Env.Long("IOXIDE_QUIC_RETENTION_BYTES", 16L << 20),
                             handshakeTimeoutMs: Env.Int("IOXIDE_TLS_HANDSHAKE_MS", tlsDefault.HandshakeTimeoutMs))
            : null;

        // ── the engine ───────────────────────────────────────────────────────────────────────
        var server = new ServerConfig
        {
            ReactorCount = reactors,
            RingEntries  = Env.UInt("IOXIDE_SQ_ENTRIES", srvDefault.RingEntries),
            DualStack    = Env.Bool("IOXIDE_DUAL_STACK", srvDefault.DualStack),

            // ENTRY DEFAULTS. The upload profile moves large bodies and each recv slice is capped
            // at the buffer size, so buffer size trades directly against slice count (CQEs +
            // returns) for the same bytes; slots × size is the reserved recv memory per reactor.
            // 16 KB × 256 was measured here, against the library's 32 KB × 4096.
            RecvBufferSize = Env.Int("IOXIDE_RECV_BUF_KB", 16) * 1024,
            RecvSlots      = Env.Int("IOXIDE_RECV_SLOTS", 256),

            // Per-connection buffer rings (IOU_PBUF_RING_INC, kernel 6.12+). Setting it IS
            // enabling the mode, and the two shared-ring knobs above then go unused - so it stays
            // null unless asked for.
            Incremental = Env.Bool("IOXIDE_INCREMENTAL", false)
                ? new IncrementalOptions
                {
                    MaxConnections = Env.Int("IOXIDE_INC_CONNS", incDefault.MaxConnections),
                    RecvSlots      = Env.Int("IOXIDE_INC_SLOTS", incDefault.RecvSlots),
                    RecvBufferSize = Env.Int("IOXIDE_INC_BUF", incDefault.RecvBufferSize),
                }
                : null,

            Tcp = new TcpOptions
            {
                Port = port,
                // One handler, several doors: a connection carries the port it arrived on, which
                // is how the TLS port serves h1-over-TLS and the h2 port serves h2, without a
                // second server. Handler.HandleAsync compares against these same values.
                ExtraPorts       = tls ? [tlsPort, h2Port] : [],
                ListenBacklog    = Env.Int("IOXIDE_BACKLOG", tcpDefault.ListenBacklog),
                // ENTRY DEFAULT: 128 KB against the library's 16 KB, so a static response fits one
                // slab and the handler sends it without chunk-flushing.
                WriteSlabSize    = Env.Int("IOXIDE_WRITE_SLAB_KB", 128) * 1024,
                PoolMax          = Env.Int("IOXIDE_POOL_MAX", tcpDefault.PoolMax),
                WriteOverflow    = Env.Enum("IOXIDE_WRITE_OVERFLOW", tcpDefault.WriteOverflow),
                ZeroCopySend     = Env.Bool("IOXIDE_ZERO_COPY", tcpDefault.ZeroCopySend),
                RecvQueueEntries = Env.Int("IOXIDE_RECV_QUEUE", tcpDefault.RecvQueueEntries),
            },

            // QUIC binds its own port; this is the tunable set it shares. SocketBufferBytes is a
            // REQUEST the kernel clamps to net.core.rmem_max - and per ioxide's own measurement,
            // granting the full 8 MiB cost ~45% at saturation because a deep standing queue
            // replaced early drops. Left at the library default, exposed so it can be measured.
            Udp = new UdpOptions
            {
                Ports             = [],
                RecvSlots         = Env.Int("IOXIDE_UDP_SLOTS", udpDefault.RecvSlots),
                SocketBufferBytes = Env.Int("IOXIDE_UDP_SOCKBUF", udpDefault.SocketBufferBytes),
                Gro               = Env.Bool("IOXIDE_UDP_GRO", udpDefault.Gro),
            },

            Quic = quic == null ? null : new QuicOptions
            {
                Port              = Env.Port("IOXIDE_QUIC_PORT", h2Port),
                LocalCidLength    = (int)cidLength,   // must match the engine's cidLength
                Routing           = Env.Enum("IOXIDE_QUIC_ROUTING", quicDefault.Routing),
                PinMigratedPeers  = Env.Bool("IOXIDE_QUIC_PIN_MIGRATED", quicDefault.PinMigratedPeers),
                IdleTimeoutMs     = Env.Int("IOXIDE_QUIC_IDLE_MS", quicDefault.IdleTimeoutMs),
                ConnectionFactory = quic.CreateFactory(),
            },
        };

        return new Config
        {
            Tls          = tls,
            TlsPort      = tlsPort,
            H2Port       = h2Port,
            DatasetPath  = Env.Str("IOXIDE_DATASET", "/data/dataset.json"),
            StaticRoot   = Env.Str("IOXIDE_STATIC", "/data/static"),
            Server       = server,
            H1TlsOptions = h1Tls,
            H2TlsOptions = h2Tls,
            QuicEngine   = quic,

            Http2 = new Http2Options
            {
                MaxRequestBytes      = Env.Int("IOXIDE_H2_MAX_REQUEST_BYTES", h2Default.MaxRequestBytes),
                MaxFrameSize         = Env.Int("IOXIDE_H2_MAX_FRAME", h2Default.MaxFrameSize),
                InitialWindowSize    = Env.Int("IOXIDE_H2_WINDOW", h2Default.InitialWindowSize),
                MaxConcurrentStreams = Env.Int("IOXIDE_H2_MAX_STREAMS", h2Default.MaxConcurrentStreams),
                MaxHeaderListSize    = Env.Int("IOXIDE_H2_MAX_HEADER_LIST", h2Default.MaxHeaderListSize),
                StreamRequestBodies  = Env.Bool("IOXIDE_H2_STREAM_BODIES", h2Default.StreamRequestBodies),
            },

            // QPACK: 0 keeps every header literal, which costs bytes but never blocks a stream on
            // a table update. Raising the capacity without also allowing blocked streams would let
            // a reference to a not-yet-acknowledged entry stall the stream, so the two move together.
            Http3 = new Nghttp3Options
            {
                QpackDynamicTableCapacity = Env.Long("IOXIDE_QPACK_CAPACITY", h3Default.QpackDynamicTableCapacity),
                QpackBlockedStreams       = Env.Long("IOXIDE_QPACK_BLOCKED_STREAMS", h3Default.QpackBlockedStreams),
            },

            Pg = BuildPg(reactors),
        };
    }

    /// <summary>Postgres from DATABASE_URL (the validation/benchmark sidecar); null when unset.</summary>
    private static PgOptions? BuildPg(int reactors)
    {
        string? url = Env.StrOrNull("DATABASE_URL");
        if (url == null) return null;

        var uri = new Uri(url);
        string[] userInfo = uri.UserInfo.Split(':', 2);
        var pgDefault = new PgOptions { User = "", Database = "" };

        // The sidecar's max_connections is the budget for the whole process, so each reactor's
        // pool is that divided by the reactor count - clamped so a small box still gets one and a
        // large one doesn't open hundreds of idle backends.
        int maxConn = Env.Int("DATABASE_MAX_CONN", 256);

        return new PgOptions
        {
            Host             = ResolveIPv4(uri.Host),
            Port             = (ushort)(uri.Port > 0 ? uri.Port : 5432),
            User             = userInfo[0],
            Password         = userInfo.Length > 1 ? userInfo[1] : null,
            Database         = uri.AbsolutePath.TrimStart('/'),
            PoolSize         = Env.Int("IOXIDE_PG_POOL", Math.Clamp(maxConn / reactors, 1, 8)),
            MaxReceiveBytes  = Env.Int("IOXIDE_PG_MAX_RECV_BYTES", pgDefault.MaxReceiveBytes),
            CommandTimeoutMs = Env.Int("IOXIDE_PG_TIMEOUT_MS", pgDefault.CommandTimeoutMs),
        };
    }

    /// <summary>RingSocket dials IPv4 literals; resolve names (e.g. "localhost") once, at startup.</summary>
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

    /// <summary>
    /// Print the resolved configuration. Worth the lines: a benchmark result is only reproducible
    /// if the run says what it ran with, and half of these are reachable from the environment.
    /// </summary>
    public void Describe(int datasetCount, int staticCount, int precompressedCount)
    {
        TcpOptions tcp = Server.Tcp!;
        UdpOptions udp = Server.Udp!;

        Console.WriteLine($"[ioxide] {Server.ReactorCount} reactors on :{tcp.Port} "
                        + $"(ProcessorCount={Environment.ProcessorCount}, dataset={datasetCount} items, "
                        + $"static={staticCount} files ({precompressedCount} precompressed), "
                        + $"pg={(Pg != null ? $"{Pg.Host}:{Pg.Port}/{Pg.Database} pool={Pg.PoolSize}" : "off")}, "
                        + $"tls={(Tls ? $"h1 :{TlsPort}, h2 :{H2Port}, h3 udp:{Server.Quic!.Port}" : "off")})");

        Console.WriteLine($"[cfg] engine: sqEntries={Server.RingEntries} recvBuf={Server.RecvBufferSize} "
                        + $"recvSlots={Server.RecvSlots} dualStack={Server.DualStack} "
                        + $"incremental={(Server.Incremental is { } inc ? $"conns={inc.MaxConnections} slots={inc.RecvSlots} buf={inc.RecvBufferSize}" : "off")}");

        Console.WriteLine($"[cfg] tcp: extraPorts=[{string.Join(',', tcp.ExtraPorts)}] backlog={tcp.ListenBacklog} "
                        + $"writeSlab={tcp.WriteSlabSize} poolMax={tcp.PoolMax} overflow={tcp.WriteOverflow} "
                        + $"zeroCopy={tcp.ZeroCopySend} recvQueue={tcp.RecvQueueEntries}");

        if (Server.Quic is { } q)
        {
            Console.WriteLine($"[cfg] udp: slots={udp.RecvSlots} sockBuf={udp.SocketBufferBytes} gro={udp.Gro}");
            Console.WriteLine($"[cfg] quic: port={q.Port} cidLen={q.LocalCidLength} routing={q.Routing} "
                            + $"pinMigrated={q.PinMigratedPeers} idleMs={q.IdleTimeoutMs}");
            Console.WriteLine($"[cfg] h3: qpackCapacity={Http3.QpackDynamicTableCapacity} "
                            + $"qpackBlockedStreams={Http3.QpackBlockedStreams}");
        }

        if (H1TlsOptions is { } t)
        {
            Console.WriteLine($"[cfg] tls: ktlsTx={t.KernelTx} (pinned) ktlsRx={t.KernelRx} handshakeMs={t.HandshakeTimeoutMs} "
                            + $"minVersion={t.MinProtocolVersion} suites={t.CipherSuites ?? "openssl"} "
                            + $"ciphers={t.CipherList ?? "openssl"}");
            Console.WriteLine($"[cfg] h2: maxStreams={Http2.MaxConcurrentStreams} window={Http2.InitialWindowSize} "
                            + $"maxFrame={Http2.MaxFrameSize} maxRequest={Http2.MaxRequestBytes} "
                            + $"maxHeaderList={Http2.MaxHeaderListSize} streamBodies={Http2.StreamRequestBodies}");
        }

        if (Pg is { } pg)
        {
            Console.WriteLine($"[cfg] pg: pool={pg.PoolSize}/reactor maxRecv={pg.MaxReceiveBytes} timeoutMs={pg.CommandTimeoutMs}");
        }
    }
}
