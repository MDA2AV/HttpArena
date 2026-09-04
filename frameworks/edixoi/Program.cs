using System.Runtime.InteropServices;

using ioxide;
using ioxide.timer;
using ioxide.tls;
using ioxide.utils;

namespace Edixoi;

/// <summary>
/// edixoi - the ioxide runtime on the arena's HTTP/1.1 profiles, hand-written on the raw
/// recv/send API. One reactor per core, each owning its ring and its share of the SO_REUSEPORT
/// listeners; no framework sits between the socket and the answer.
///
///     :8080  baseline, limited-conn, latency-1m, latency-10k   GET|POST /baseline11?a=&amp;b=
///            async                                            GET      /delay/{ms}
///     :8081  json-tls                                          GET      /json/{count}?m=N
///            8gbit                                             POST     /echo
///
/// One handler serves both doors: a connection carries the port it arrived on, and the only
/// difference is whether a <see cref="TlsSession"/> sits in front of the bytes.
///
/// See <see cref="Http1"/> for the parsing and the routing. This file is the transport.
/// </summary>
internal static class Program
{
    /// <summary>
    /// Connection: close is an HTTP decision, so honouring it is this entry's job - ioxide moves
    /// bytes and knows nothing about HTTP. Half-closing the write side is what puts the FIN the
    /// peer is waiting for on the wire.
    ///
    /// SHUT_WR rather than close(2), deliberately: the descriptor belongs to ioxide, which closes
    /// it once its own reference goes, and closing it here would free a number the reactor still
    /// holds - the next accept could then hand the same integer to somebody else.
    /// </summary>
    private const int ShutWr = 1;

    [DllImport("libc", EntryPoint = "shutdown", SetLastError = true)]
    private static extern int Shutdown(int fd, int how);

    private static ushort _tlsPort;
    private static Dataset _dataset = Dataset.Empty;

    private static void Main()
    {
        ushort port = Port("EDIXOI_PORT", 8080);
        _tlsPort = Port("EDIXOI_TLS_PORT", 8081);
        int reactors = int.TryParse(Environment.GetEnvironmentVariable("EDIXOI_REACTORS"), out int r)
            ? r
            // ProcessorCount counts logical CPUs, so a hyperthreaded box would otherwise start
            // twice the rings it has cores to run them on.
            : Math.Min(Environment.ProcessorCount, 64);

        // The harness mounts both. Without them the TLS door does not open and the plaintext
        // profiles still run, which is what makes this runnable outside the harness.
        string certPath = Environment.GetEnvironmentVariable("TLS_CERT") ?? "/certs/server.crt";
        string keyPath = Environment.GetEnvironmentVariable("TLS_KEY") ?? "/certs/server.key";
        bool tls = File.Exists(certPath) && File.Exists(keyPath);

        _dataset = Dataset.Load(Environment.GetEnvironmentVariable("EDIXOI_DATASET") ?? "/data/dataset.json");

        var config = new ServerConfig
        {
            ReactorCount = reactors,
            Tcp = new TcpOptions
            {
                Port = port,
                // One handler, two doors. Everything else is left at ioxide's own defaults, which
                // is the honest configuration for an entry whose point is what the runtime does
                // unassisted.
                ExtraPorts = tls ? [_tlsPort] : [],
            },
        };

        // The mounted certificate as it is: ALPN is already ["http/1.1"], which is what both TLS
        // profiles require, and minting one of our own would quietly buy a faster signature than
        // the harness handed everyone else.
        //
        // KernelTx is the one TLS knob moved off its default. The handler's plaintext goes into
        // the write slab and the kernel makes the records, which is one pass over the bytes
        // instead of OpenSSL's encrypt-then-copy.
        //
        // Only when the kernel actually offers the ULP: ioxide throws on the handoff when the tls
        // module is missing, and a TLS port that refuses every connection is a far worse trade
        // than an encrypt.
        //
        // Receive stays in userspace, and that is measured rather than assumed - kernel RX cost
        // about 3% on json-tls here (792,642 / 796,898 and 797,053 / 802,664 against 772,330 /
        // 776,448 and 772,363 / 770,476) and did nothing for the echo. It would also buy a
        // failure mode: under kTLS RX a TLS 1.3 KeyUpdate or alert is only readable through
        // recvmsg with a control message, and the reactor's hot path is IORING_OP_RECV, which
        // carries none - so the kernel refuses the read and that connection is lost. Paying 3%
        // for that is the wrong way round.
        var tlsOptions = new TlsOptions
        {
            CertificatePath = certPath,
            KeyPath = keyPath,
            KernelTx = KernelTlsAvailable(),
        };

        Console.WriteLine($"[edixoi] {reactors} reactors on :{port}"
                        + (tls ? $" + :{_tlsPort} tls ({(tlsOptions.KernelTx ? "kernel tx" : "openssl tx")})"
                               : " (no tls: certificate not mounted)")
                        + $", dataset={_dataset.Count} items (ProcessorCount={Environment.ProcessorCount})");

        var threads = new Thread[reactors];

        for (int i = 0; i < threads.Length; i++)
        {
            var reactor = new Reactor(i, config);

            reactor.OnStart = r =>
            {
                // Per reactor, not per connection. Serve() never awaits, and a reactor runs one
                // thread, so no connection can be inside it while another is - which makes the
                // parser's buffers shareable and a connection free to open. It matters: the
                // limited-conn profile closes every connection after ten requests, so anything
                // allocated per connection is allocated a quarter of a million times a second.
                r.AddService(new Http1(_dataset));

                if (tls)
                {
                    // Built here too, so the OpenSSL context belongs to the thread that uses it.
                    TlsService.Start(r, tlsOptions);
                }
            };

            reactor.TcpHandle = ServeAsync;

            threads[i] = new Thread(reactor.Run) { Name = $"reactor-{i}" };
            threads[i].Start();
        }

        foreach (Thread thread in threads)
        {
            thread.Join();
        }
    }

    private static ushort Port(string name, ushort fallback)
        => ushort.TryParse(Environment.GetEnvironmentVariable(name), out ushort value) ? value : fallback;

    /// <summary>Whether this kernel will take the TLS handoff at all - asked once, at startup.</summary>
    private static bool KernelTlsAvailable()
    {
        const string path = "/proc/sys/net/ipv4/tcp_available_ulp";

        try
        {
            return File.Exists(path) &&
                   File.ReadAllText(path).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
                       .Contains("tls");
        }
        catch (IOException)
        {
            return false;   // cannot ask, so do not assume
        }
    }

    /// <summary>
    /// One connection, start to finish, on the reactor thread that accepted it. Every await
    /// resumes right back on it, so nothing here is shared and nothing is locked.
    /// </summary>
    private static async Task ServeAsync(Reactor reactor, TcpConnection conn)
    {
        var session = new Session(reactor, conn, reactor.GetService<Http1>());

        try
        {
            if (conn.ListenerPort == _tlsPort)
            {
                session.Tls = await reactor.GetService<TlsService>().AcceptAsync(conn);

                // A request can ride in with the handshake's last flight, so it is fed and served
                // before the loop parks on a read that would otherwise never come.
                session.FeedHandshakeRemainder();
                if (await session.PumpAsync())
                {
                    await conn.FlushAsync();
                }
            }

            while (!session.Close)
            {
                RecvSnapshot snapshot = await conn.ReadAsync();
                session.Feed(conn, snapshot);

                if (await session.PumpAsync())
                {
                    await conn.FlushAsync();
                }

                if (snapshot.IsClosed)
                {
                    return;
                }

                conn.ResetRead();
            }

            Shutdown(conn.ClientFd, ShutWr);
        }
        finally
        {
            session.Tls?.Dispose();
            conn.DecRef();
        }
    }

    /// <summary>
    /// One connection's state: the bytes not yet answered, the parser over them, and the timer
    /// the delay endpoint waits on. It exists so the read loop above stays a read loop - the
    /// awaiting is here, where the state it resumes into lives.
    /// </summary>
    private sealed class Session(Reactor reactor, TcpConnection conn, Http1 http)
    {
        private readonly Carry _carry = new();
        private RingTimer? _timer;

        public TlsSession? Tls;
        public bool Close;

        private Sink Sink => new(conn, Tls);

        /// <summary>Plaintext the handshake's final flight carried in ahead of the first read.</summary>
        public void FeedHandshakeRemainder() => _carry.Append(Tls!.DrainPlaintext());

        /// <summary>Everything the ring delivered, decrypted when this is a TLS connection.</summary>
        public void Feed(TcpConnection connection, in RecvSnapshot snapshot)
        {
            while (connection.TryGetItem(snapshot, out SpscRecvRing.Item item))
            {
                if (item.HasBuffer)
                {
                    _carry.Append(Plain(Tls, in item));
                    connection.ReturnBuffer(in item);
                }
            }
        }

        /// <summary>
        /// Answer everything held, waiting on the ring for any request that asked to be delayed.
        /// True when something was written and the caller owes a flush.
        /// </summary>
        public async Task<bool> PumpAsync()
        {
            bool answered = false;

            while (true)
            {
                answered |= ServeHeld(out int delayMs) > 0;

                if (delayMs == Http1.NoDelay)
                {
                    return answered || Close;
                }

                // The wait rides this reactor's ring: the deadline goes to the kernel with the
                // submission and the completion arrives back on this thread, so a held connection
                // costs a deadline rather than a thread. One timer per connection, re-armed - a
                // connection only ever waits on one request at a time.
                _timer ??= new RingTimer(reactor);
                await _timer.DelayAsync(delayMs);

                Http1.WriteDelayed(Sink, delayMs, Close);
                answered = true;
            }
        }

        /// <summary>
        /// The synchronous half, kept out of the async method above: spans and the parser live
        /// here, and nothing they touch has to survive an await.
        /// </summary>
        private int ServeHeld(out int delayMs)
        {
            bool close = Close;
            int consumed = http.Serve(Sink, _carry.Span, ref close, out delayMs);
            Close = close;
            _carry.Consume(consumed);
            return consumed;
        }
    }

    /// <summary>
    /// Bytes in, decrypted when the connection is a TLS one. The pointer work lives here because
    /// an async method cannot contain it; the plaintext stays valid until the next decrypt, which
    /// is why it is copied into the carry straight away.
    /// </summary>
    private static unsafe ReadOnlySpan<byte> Plain(TlsSession? tls, in SpscRecvRing.Item item)
        => tls is null ? item.AsSpan() : tls.Decrypt(item.Ptr, item.Len);

    /// <summary>
    /// What has arrived and not yet been answered. A read that carries whole requests leaves it
    /// empty again; a request split across reads is held here until the rest of it lands.
    /// </summary>
    private sealed class Carry
    {
        // Per connection it has to be - it holds a request split across reads - so it is the one
        // buffer paid for on every accept. It starts empty and grows to whatever this connection
        // actually sees; a baseline request is about a hundred bytes.
        private byte[] _buffer = [];
        private int _length;

        public ReadOnlySpan<byte> Span => _buffer.AsSpan(0, _length);

        public void Append(ReadOnlySpan<byte> arrived)
        {
            if (arrived.IsEmpty)
            {
                return;
            }

            if (_buffer.Length < _length + arrived.Length)
            {
                Array.Resize(ref _buffer, Math.Max(_length + arrived.Length, _buffer.Length * 2));
            }

            arrived.CopyTo(_buffer.AsSpan(_length));
            _length += arrived.Length;
        }

        public void Consume(int count)
        {
            if (count >= _length)
            {
                _length = 0;
                return;
            }

            // Overlapping move, which Span.CopyTo does rather than forbids.
            _buffer.AsSpan(count, _length - count).CopyTo(_buffer);
            _length -= count;
        }
    }
}
