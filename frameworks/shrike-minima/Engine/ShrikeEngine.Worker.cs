// ReSharper disable always CheckNamespace
// ReSharper disable always SuggestVarOrType_BuiltInTypes
// ReSharper disable always StackAllocInsideLoop
#pragma warning disable CA2014

namespace Shrike;

public sealed partial class ShrikeEngine
{
    // Pooled Connection instances (reused across fds to avoid per-connection allocation).
    private static readonly ObjectPool<Connection> ConnectionPool =
        new DefaultObjectPool<Connection>(new ConnectionPoolPolicy(), 1024 * 32);

    private sealed class ConnectionPoolPolicy : PooledObjectPolicy<Connection>
    {
        public override Connection Create() => new(_maxNumberConnectionsPerWorker, _inSlabSize, _outSlabSize);
        public override bool Return(Connection connection) { connection.Clear(); return true; }
    }

    /// <summary>
    /// Worker event loop. It is purely a DRIVER for each connection's IVTS — the
    /// read/parse/write/flush loop lives in the injected handler (see HandleAsync),
    /// which awaits <see cref="Connection.ReadAsync"/>/<see cref="Connection.FlushAsync"/>:
    ///   - EPOLLIN  → drain recv → SignalReadable (resumes the handler inline)
    ///   - EPOLLOUT → continue the partial send → on drain CompleteFlush (resumes inline)
    ///   - error/hup/peer-close → MarkClosed (handler exits inline) → recycle
    /// Continuations run inline (RunContinuationsAsynchronously=false), so handler and
    /// driver share this one worker thread — cooperative, no cross-thread races.
    /// </summary>
    private static unsafe void WorkerLoop(Worker W)
    {
        var connections = new Dictionary<int, Connection>(capacity: _maxNumberConnectionsPerWorker);

        for (;;)
        {
            int n = epoll_wait(W.Ep, W.EventsBuf, W.MaxEvents, -1);
            if (n < 0) { if (Marshal.GetLastPInvokeError() == EINTR) continue; throw new Exception("epoll_wait worker"); }

            for (int i = 0; i < n; i++)
            {
                ReadEpollEvent((byte*)W.EventsBuf + i * EvSize, out uint evs, out int fd);

                // 1) Our own SO_REUSEPORT listener is readable — drain accepts.
                if (fd == W.ListenFd)
                {
                    for (;;)
                    {
                        int cfd = accept4(W.ListenFd, IntPtr.Zero, IntPtr.Zero, SOCK_NONBLOCK | SOCK_CLOEXEC);
                        if (cfd >= 0)
                        {
                            int one = 1;
                            setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, ref one, sizeof(int));

                            byte* ev = stackalloc byte[EvSize];
                            WriteEpollEvent(ev, EPOLLIN | EPOLLRDHUP | EPOLLERR | EPOLLHUP | EPOLLET, cfd);
                            epoll_ctl(W.Ep, EPOLL_CTL_ADD, cfd, (IntPtr)ev);

                            Connection c = ConnectionPool.Get();
                            c.Reset(cfd, W.Ep);
                            connections[cfd] = c;
                            _ = RunHandler(c);   // suspends immediately on its first ReadAsync
                            continue;
                        }
                        int err = Marshal.GetLastPInvokeError();
                        if (err == EINTR) continue;
                        break;   // EAGAIN/EWOULDBLOCK (drained) or transient error
                    }
                    continue;
                }

                if (!connections.TryGetValue(fd, out var conn)) { CloseQuiet(fd); continue; }

                // 2) Error / hangup / remote half-close.
                if ((evs & (EPOLLERR | EPOLLHUP | EPOLLRDHUP)) != 0)
                {
                    conn.MarkClosed();          // resumes & exits the handler inline
                    CloseConn(fd, connections);
                    continue;
                }

                // 3) Read-ready. Minima-style: the worker recv's into POOLED buffers and
                //    hands them to the handler via the per-connection SPSC ring. The worker
                //    and handler never share a buffer, so there is no driver/handler race.
                if ((evs & EPOLLIN) != 0)
                {
                    bool closed = false;
                    while (true)
                    {
                        byte* buf = RecvPool.Take();
                        long got = recv(fd, buf, (ulong)RecvPool.BufSize, 0);
                        if (got > 0)
                        {
                            if (!conn.RecvRing.TryEnqueue(buf, (int)got)) { RecvPool.Return(buf); break; } // ring full
                            continue;
                        }
                        RecvPool.Return(buf);
                        if (got == 0) { closed = true; break; }   // peer closed
                        int err = Marshal.GetLastPInvokeError();
                        if (err is EAGAIN or EWOULDBLOCK) break; // drained
                        if (err == EINTR) continue;
                        closed = true; break;                    // hard error
                    }
                    if (closed)
                    {
                        conn.MarkClosed();
                        CloseConn(fd, connections);
                        continue;
                    }
                    conn.SignalReadable();
                    if (conn.IsClosed) CloseConn(fd, connections);
                    continue;
                }

                // 4) Write-ready (a previous flush was partial).
                if ((evs & EPOLLOUT) != 0)
                {
                    Connection.FlushResult r = conn.TryFlush();
                    if (r == Connection.FlushResult.Complete)
                    {
                        conn.ArmEpollIn();
                        conn.CompleteFlush();    // resume handler inline: loops back to ReadAsync
                        if (conn.IsClosed) CloseConn(fd, connections);
                    }
                    else if (r == Connection.FlushResult.Close)
                    {
                        conn.MarkClosed();
                        CloseConn(fd, connections);
                    }
                    // Incomplete: stay armed for EPOLLOUT.
                }
            }
        }
    }

    /// <summary>Runs the injected per-connection handler; guarantees the connection is closed when it ends.</summary>
    private static async Task RunHandler(Connection conn)
    {
        try { await _sHandler(conn); }
        catch { /* handler faulted */ }
        finally { conn.MarkClosed(); }   // idempotent; the worker recycles once it observes IsClosed
    }

    /// <summary>Drain recv into the connection buffer (edge-triggered: read until EAGAIN). False = peer closed / hard error.</summary>
    private static unsafe bool RecvDrain(Connection conn, int fd)
    {
        while (true)
        {
            int avail = _inSlabSize - conn.Tail;
            if (avail == 0) return true;   // buffer full — handler must drain it (large-request limit, as in Unhinged)

            long got = recv(fd, conn.ReceiveBuffer + conn.Tail, (ulong)avail, 0);
            if (got > 0) { conn.Tail += (int)got; continue; }
            if (got == 0) return false;    // peer closed

            int err = Marshal.GetLastPInvokeError();
            if (err is EAGAIN or EWOULDBLOCK) return true;   // drained
            if (err == EINTR) continue;
            return false;                  // ECONNRESET / EPIPE / unexpected
        }
    }

    // ===== Close helpers =====

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static void CloseConn(int fd, Dictionary<int, Connection> map)
    {
        if (map.Remove(fd, out var c))
        {
            ConnectionPool.Return(c);
            CloseQuiet(fd);
        }
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static void CloseQuiet(int fd) { try { close(fd); } catch { /* best effort */ } }
}
