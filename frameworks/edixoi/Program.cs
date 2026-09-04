using System.Runtime.InteropServices;

using ioxide;
using ioxide.utils;

namespace Edixoi;

/// <summary>
/// edixoi - the ioxide runtime on the arena's HTTP/1.1 connection profiles, and nothing else.
/// One reactor per core, each owning its ring and its share of the SO_REUSEPORT listener; the
/// HTTP is hand-written on the raw recv/send API, so no framework sits between the socket and
/// the answer.
///
/// Two profiles, one endpoint:
///     baseline      4,096 held keep-alive connections, GET/POST/chunked rotated
///     limited-conn  the same, each connection closed after 10 requests
///
/// See <see cref="Http1"/> for the parsing. This file is the transport: read, hand the bytes over,
/// send what came back.
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

    private static void Main()
    {
        // The only two knobs. Everything else is left at ioxide's own defaults, which is the
        // honest configuration for an entry whose point is what the runtime does unassisted.
        ushort port = ushort.TryParse(Environment.GetEnvironmentVariable("EDIXOI_PORT"), out ushort p) ? p : (ushort)8080;
        int reactors = int.TryParse(Environment.GetEnvironmentVariable("EDIXOI_REACTORS"), out int r)
            ? r
            // ProcessorCount counts logical CPUs, so a hyperthreaded box would otherwise start
            // twice the rings it has cores to run them on.
            : Math.Min(Environment.ProcessorCount, 64);

        var config = new ServerConfig
        {
            ReactorCount = reactors,
            Tcp = new TcpOptions { Port = port },
        };

        Console.WriteLine($"[edixoi] {reactors} reactors on :{port} (ProcessorCount={Environment.ProcessorCount})");

        var threads = new Thread[reactors];

        for (int i = 0; i < threads.Length; i++)
        {
            var reactor = new Reactor(i, config);
            reactor.TcpHandle = ServeAsync;

            threads[i] = new Thread(reactor.Run) { Name = $"reactor-{i}" };
            threads[i].Start();
        }

        foreach (Thread thread in threads)
        {
            thread.Join();
        }
    }

    /// <summary>
    /// One connection, start to finish, on the reactor thread that accepted it. Every await
    /// resumes right back on it, so nothing here is shared and nothing is locked.
    /// </summary>
    private static async Task ServeAsync(Reactor _, TcpConnection conn)
    {
        var carry = new Carry();
        bool close = false;

        try
        {
            while (true)
            {
                RecvSnapshot snapshot = await conn.ReadAsync();
                bool answered = false;

                while (conn.TryGetItem(snapshot, out SpscRecvRing.Item item))
                {
                    if (!item.HasBuffer)
                    {
                        continue;
                    }

                    // Nothing held over means the ring's own bytes are the whole request, so they
                    // are parsed where they lie; otherwise last read's tail has to lead.
                    ReadOnlySpan<byte> pending = carry.Length == 0 ? item.AsSpan() : carry.Join(item.AsSpan());
                    int consumed = Http1.Serve(conn, pending, ref close);

                    carry.Keep(pending[consumed..]);
                    answered |= consumed > 0;

                    conn.ReturnBuffer(in item);
                }

                // close without a consumed request is the oversized-head 400, which still owes
                // the peer its bytes.
                if (answered || close)
                {
                    await conn.FlushAsync();   // one send per read, however many requests it held
                }

                if (close)
                {
                    Shutdown(conn.ClientFd, ShutWr);
                    return;
                }

                if (snapshot.IsClosed)
                {
                    return;
                }

                conn.ResetRead();
            }
        }
        finally
        {
            // Hands the connection object back to the reactor's pool and closes the socket, which
            // is what a peer that asked for Connection: close is waiting to see.
            conn.DecRef();
        }
    }

    /// <summary>
    /// The tail of a request that arrived split across reads. Empty on the common path - a read
    /// that carries whole requests leaves nothing behind - so it costs a length check per read.
    /// </summary>
    private sealed class Carry
    {
        private byte[] _buffer = [];

        public int Length { get; private set; }

        /// <summary>What was held, followed by what just arrived.</summary>
        public ReadOnlySpan<byte> Join(ReadOnlySpan<byte> arrived)
        {
            Grow(Length + arrived.Length);
            arrived.CopyTo(_buffer.AsSpan(Length));
            Length += arrived.Length;
            return _buffer.AsSpan(0, Length);
        }

        /// <summary>Hold what the parser could not use. Copies nothing when it used everything.</summary>
        public void Keep(ReadOnlySpan<byte> rest)
        {
            if (rest.IsEmpty)
            {
                Length = 0;
                return;
            }

            // rest is usually a slice of this same buffer, which is legal: Span.CopyTo moves
            // overlapping regions rather than forbidding them.
            Grow(rest.Length);
            rest.CopyTo(_buffer);
            Length = rest.Length;
        }

        private void Grow(int needed)
        {
            if (_buffer.Length < needed)
            {
                Array.Resize(ref _buffer, Math.Max(needed, Math.Max(_buffer.Length * 2, 2048)));
            }
        }
    }
}
