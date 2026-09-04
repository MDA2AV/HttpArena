using System.Buffers;
using System.IO.Pipelines;
using System.Runtime.InteropServices;

using ioxide;
using ioxide.timer;
using ioxide.tls;

namespace IoxidePipes;

/// <summary>
/// ioxide-pipes - the ioxide runtime on the arena's HTTP/1.1 profiles, served through the
/// System.IO.Pipelines surface rather than its raw recv/send API, with Glyph11 parsing what comes
/// off it.
///
///     :8080  baseline, limited-conn, latency-1m, latency-10k   GET|POST /baseline11?a=&amp;b=
///            async                                             GET      /delay/{ms}
///     :8081  json-tls                                          GET      /json/{count}?m=N
///            8gbit                                             POST     /echo
///
/// The pipe is what carries the design, twice over. Its reader owns the carry: unconsumed bytes
/// are held across reads with no copy and no buffer of ours, so a request split over several
/// recvs is handed to the parser as one sequence. And the TLS door needs no second serve loop -
/// <see cref="TlsConnectionDualPipe"/> is an IDuplexPipe like any other, so
/// <see cref="ServeAsync"/> below is written once and never learns which one it got.
///
/// See <see cref="Http1"/> for what is done with the bytes. This file is the transport.
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
        ushort port = Port("IOXIDE_PIPES_PORT", 8080);
        _tlsPort = Port("IOXIDE_PIPES_TLS_PORT", 8081);
        int reactors = int.TryParse(Environment.GetEnvironmentVariable("IOXIDE_PIPES_REACTORS"), out int r)
            ? r
            // ProcessorCount counts logical CPUs, so a hyperthreaded box would otherwise start
            // twice the rings it has cores to run them on.
            : Math.Min(Environment.ProcessorCount, 64);

        // The harness mounts both. Without them the TLS door does not open and the plaintext
        // profiles still run, which is what makes this runnable outside the harness.
        string certPath = Environment.GetEnvironmentVariable("TLS_CERT") ?? "/certs/server.crt";
        string keyPath = Environment.GetEnvironmentVariable("TLS_KEY") ?? "/certs/server.key";
        bool tls = File.Exists(certPath) && File.Exists(keyPath);

        _dataset = Dataset.Load(Environment.GetEnvironmentVariable("IOXIDE_PIPES_DATASET") ?? "/data/dataset.json");

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

        // The mounted certificate as it is, and the library's TLS defaults otherwise: ALPN is
        // already ["http/1.1"], which is what both TLS profiles require. Minting a certificate of
        // our own here would quietly buy a faster signature than the harness handed everyone else.
        var tlsOptions = new TlsOptions { CertificatePath = certPath, KeyPath = keyPath };

        Console.WriteLine($"[ioxide-pipes] {reactors} reactors on :{port}"
                        + (tls ? $" + :{_tlsPort} tls" : " (no tls: certificate not mounted)")
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

    /// <summary>
    /// One connection, start to finish, on the reactor thread that accepted it. Every await
    /// resumes right back on it, so nothing here is shared and nothing is locked.
    /// </summary>
    private static async Task ServeAsync(Reactor reactor, TcpConnection conn)
    {
        TlsSession? tls = null;
        TlsConnectionDualPipe? tlsPipe = null;

        try
        {
            IDuplexPipe pipe;

            if (conn.ListenerPort == _tlsPort)
            {
                tls = await reactor.GetService<TlsService>().AcceptAsync(conn);

                // The whole of the TLS integration. Below this line nothing knows which pipe it
                // got, including the request a client bundled with its handshake - the reader
                // carries that plaintext in and it is the first thing ReadAsync returns.
                tlsPipe = new TlsConnectionDualPipe(conn, tls, ownsSession: false);
                pipe = tlsPipe;
            }
            else
            {
                pipe = new TcpConnectionDualPipe(conn);
            }

            Http1 http = reactor.GetService<Http1>();
            RingTimer? timer = null;
            bool close = false;

            while (true)
            {
                ReadResult read = await pipe.Input.ReadAsync();
                ReadOnlySequence<byte> buffer = read.Buffer;

                SequencePosition consumed = http.Serve(pipe.Output, buffer, ref close, out int delayMs);

                // consumed is where the answered requests end; examined is everything, which says
                // "there is no more to be had from this, wake me when there is". What lies between
                // them is a partial request, and the reader keeps it without a copy.
                pipe.Input.AdvanceTo(consumed, buffer.End);

                while (delayMs != Http1.NoDelay)
                {
                    // The wait rides this reactor's ring: the deadline goes to the kernel with the
                    // submission and the completion arrives back on this thread, so a held
                    // connection costs a kernel deadline rather than a thread. One timer per
                    // connection, re-armed - a connection waits on one request at a time.
                    timer ??= new RingTimer(reactor);
                    await timer.DelayAsync(delayMs);
                    Http1.WriteDelayed(pipe.Output, delayMs, close);

                    // Whatever was behind the delayed request still has to be answered, and the
                    // reader is holding it.
                    if (!pipe.Input.TryRead(out ReadResult more))
                    {
                        break;
                    }

                    consumed = http.Serve(pipe.Output, more.Buffer, ref close, out delayMs);
                    pipe.Input.AdvanceTo(consumed, more.Buffer.End);
                }

                if (pipe.Output.UnflushedBytes > 0)
                {
                    await pipe.Output.FlushAsync();   // one send per read, however many requests it held
                }

                if (close)
                {
                    Shutdown(conn.ClientFd, ShutWr);
                    return;
                }

                if (read.IsCompleted)
                {
                    return;
                }
            }
        }
        finally
        {
            if (tlsPipe is not null)
            {
                await tlsPipe.DisposeAsync();
            }

            tls?.Dispose();
            conn.DecRef();
        }
    }
}
