// ReSharper disable always CheckNamespace
// ReSharper disable always SuggestVarOrType_BuiltInTypes
// ReSharper disable always StackAllocInsideLoop
#pragma warning disable CA2014

namespace Shrike;

/// <summary>
/// One worker = one thread + one epoll instance + its OWN SO_REUSEPORT listen
/// socket. Like Minima's reactor: the kernel load-balances accepts across the N
/// per-worker listeners, so there's no acceptor thread, no fd handoff, and no
/// eventfd. Each worker accepts and serves its own connections end to end.
/// </summary>
[SkipLocalsInit]
internal sealed unsafe class Worker : IDisposable
{
    internal readonly int Index;

    // This worker's own epoll instance (client fds + the listen socket).
    internal readonly int Ep;

    // This worker's own SO_REUSEPORT listening socket.
    internal readonly int ListenFd;

    // Unmanaged buffer for epoll_wait() results (avoids per-call allocation).
    internal readonly IntPtr EventsBuf;

    // Max events per epoll_wait() batch.
    internal readonly int MaxEvents;

    internal Worker(int idx, int maxEvents, int port, int backlog)
    {
        Index = idx;
        MaxEvents = maxEvents;

        Ep = epoll_create1(EPOLL_CLOEXEC);
        if (Ep < 0)
            throw new Exception("epoll_create1 failed");

        ListenFd = OpenReusePortListener(port, backlog);

        // Register our own listen socket (level-triggered: drain accepts each wake).
        byte* ev = stackalloc byte[EvSize];
        WriteEpollEvent(ev, EPOLLIN | EPOLLERR | EPOLLHUP, ListenFd);
        if (epoll_ctl(Ep, EPOLL_CTL_ADD, ListenFd, (IntPtr)ev) != 0)
            throw new Exception("epoll_ctl ADD listen failed");

        EventsBuf = Marshal.AllocHGlobal(EvSize * MaxEvents);
    }

    /// <summary>One non-blocking SO_REUSEPORT listener per worker; the kernel balances accepts across them.</summary>
    private static int OpenReusePortListener(int port, int backlog)
    {
        int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, IPPROTO_TCP);
        if (fd < 0) throw new Exception($"socket failed errno={Marshal.GetLastPInvokeError()}");

        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, ref one, sizeof(int));
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, ref one, sizeof(int));

        int fl = fcntl(fd, F_GETFL, 0);
        if (fl >= 0) fcntl(fd, F_SETFL, fl | O_NONBLOCK);

        var addr = new sockaddr_in
        {
            sin_family = (ushort)AF_INET,
            sin_port   = Htons((ushort)port),
            sin_addr   = new in_addr { s_addr = 0 },   // 0.0.0.0
            sin_zero   = new byte[8]
        };
        if (bind(fd, ref addr, (uint)Marshal.SizeOf<sockaddr_in>()) != 0)
            throw new Exception($"bind failed errno={Marshal.GetLastPInvokeError()}");
        if (listen(fd, backlog) != 0)
            throw new Exception($"listen failed errno={Marshal.GetLastPInvokeError()}");
        return fd;
    }

    public void Dispose()
    {
        try { if (Ep >= 0) close(Ep); } catch { /* ignore */ }
        try { if (ListenFd >= 0) close(ListenFd); } catch { /* ignore */ }
        if (EventsBuf != IntPtr.Zero) Marshal.FreeHGlobal(EventsBuf);
    }
}
