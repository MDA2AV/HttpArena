using System.Buffers;
using System.IO.Pipelines;
using System.Runtime.InteropServices;

using ioxide;

namespace IoxidePipes;

/// <summary>
/// ioxide-pipes - the ioxide runtime on the arena's HTTP/1.1 connection profiles, served through
/// the System.IO.Pipelines surface rather than the raw recv/send API, with Glyph11 parsing what
/// comes off it.
///
/// The pipe is what carries the design. Its reader owns the carry: unconsumed bytes are held
/// across reads with no copy and no buffer of ours, so a request split over several recvs is
/// handed to the parser as one sequence and this file never has to reassemble anything. The
/// writer stages into the connection's own slab, so a response still leaves in one send.
///
/// Two profiles, one endpoint:
///     baseline      4,096 held keep-alive connections, GET/POST/chunked rotated
///     limited-conn  the same, each connection closed after 10 requests
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

    private static void Main()
    {
        // The only two knobs. Everything else is left at ioxide's own defaults, which is the
        // honest configuration for an entry whose point is what the runtime does unassisted.
        ushort port = ushort.TryParse(Environment.GetEnvironmentVariable("IOXIDE_PIPES_PORT"), out ushort p) ? p : (ushort)8080;
        int reactors = int.TryParse(Environment.GetEnvironmentVariable("IOXIDE_PIPES_REACTORS"), out int r)
            ? r
            // ProcessorCount counts logical CPUs, so a hyperthreaded box would otherwise start
            // twice the rings it has cores to run them on.
            : Math.Min(Environment.ProcessorCount, 64);

        var config = new ServerConfig
        {
            ReactorCount = reactors,
            Tcp = new TcpOptions { Port = port },
        };

        Console.WriteLine($"[ioxide-pipes] {reactors} reactors on :{port} (ProcessorCount={Environment.ProcessorCount})");

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
        var pipe = new TcpConnectionDualPipe(conn);
        var http = new Http1();
        bool close = false;

        try
        {
            while (true)
            {
                ReadResult read = await pipe.Input.ReadAsync();
                ReadOnlySequence<byte> buffer = read.Buffer;

                SequencePosition consumed = http.Serve(pipe.Output, buffer, ref close);

                // consumed is where the answered requests end; examined is everything, which
                // says "there is no more to be had from this, wake me when there is". What lies
                // between them is a partial request, and the reader keeps it without a copy.
                pipe.Input.AdvanceTo(consumed, buffer.End);

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
            http.Dispose();
            pipe.Input.Complete();
            conn.DecRef();
        }
    }
}
