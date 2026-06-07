using System.Threading.Tasks.Sources;

// ReSharper disable always CheckNamespace
// ReSharper disable always SuggestVarOrType_BuiltInTypes
#pragma warning disable CA2014

namespace Shrike;

/// <summary>
/// Per-connection state with Minima-style IVTS on the read and flush paths.
///
/// The epoll worker is the DRIVER: on EPOLLIN it drains recv into
/// <see cref="ReceiveBuffer"/> then calls <see cref="SignalReadable"/>; on EPOLLOUT
/// it continues <see cref="TryFlush"/> and, when drained, calls <see cref="CompleteFlush"/>.
/// The per-connection handler loop awaits <see cref="ReadAsync"/> / <see cref="FlushAsync"/>;
/// because <c>RunContinuationsAsynchronously = false</c>, those continuations run inline
/// on the worker thread — the handler and the driver are the same thread (cooperative,
/// single-threaded), exactly like Minima's reactor.
/// </summary>
[SkipLocalsInit]
public sealed unsafe class Connection : IValueTaskSource<bool>, IValueTaskSource, IDisposable
{
    public enum FlushResult { Complete, Incomplete, Close }

    // ---- recv window: valid bytes in [Head .. Tail) ----
    public int Head, Tail;
    public readonly byte* ReceiveBuffer;
    private readonly int _inSlabSize;

    // ---- send buffer ----
    public readonly FixedBufferWriter WriteBuffer;

    // ---- per-request parsed header (no allocations) ----
    public BinaryH1HeaderData BinaryH1HeaderData { get; set; }
    public H1HeaderData H1HeaderData { get; set; } = null!;

    // ---- epoll wiring (set when the connection is bound to a live fd) ----
    public int Fd;
    public int Ep;

    // ---- read IVTS (result = isClosed) ----
    private ManualResetValueTaskSourceCore<bool> _readSignal = new() { RunContinuationsAsynchronously = true };
    private int _armed;
    private int _pending;
    private int _closed;

    // ---- flush IVTS ----
    private ManualResetValueTaskSourceCore<bool> _flushSignal = new() { RunContinuationsAsynchronously = true };
    private int _flushArmed;

    public Connection(int maxConnections, int inSlabSize, int outSlabSize)
    {
        _inSlabSize = inSlabSize;
        ReceiveBuffer = (byte*)NativeMemory.AlignedAlloc((nuint)inSlabSize, 64);
        WriteBuffer = new FixedBufferWriter((byte*)NativeMemory.AlignedAlloc((nuint)outSlabSize, 64), outSlabSize);
    }

    /// <summary>
    /// Parse the next complete HTTP request from the recv window into
    /// <see cref="BinaryH1HeaderData"/> and advance past it. Returns false when no
    /// more complete requests remain, compacting any trailing partial to the front
    /// so the next recv appends after it. Call in a loop after <see cref="ReadAsync"/>.
    /// </summary>
    public bool TryReadRequest()
    {
        int idx = 0;
        ReadOnlySpan<byte> headerSpan = FindCrlfCrlf(ReceiveBuffer, Head, Tail, ref idx);
        if (idx < 0)
        {
            Compact();
            return false;
        }
        BinaryH1HeaderData = ExtractBinaryH1HeaderData(headerSpan);
        Head = idx + 4;   // advance past CRLFCRLF
        return true;
    }

    public void Compact()
    {
        if (Head == 0) return;          // nothing consumed — partial already at the front, keep it
        if (Head < Tail)
        {
            int length = Tail - Head;
            Buffer.MemoryCopy(ReceiveBuffer + Head, ReceiveBuffer, _inSlabSize, length);
            Head = 0;
            Tail = length;
        }
        else
        {
            Head = Tail = 0;            // fully consumed
        }
    }

    /// <summary>Bind to a fresh fd taken from the pool and reset all per-connection state.</summary>
    public void Reset(int fd, int ep)
    {
        Fd = fd;
        Ep = ep;
        Head = Tail = 0;
        WriteBuffer.Reset();
        Volatile.Write(ref _armed, 0);
        Volatile.Write(ref _pending, 0);
        Volatile.Write(ref _closed, 0);
        Volatile.Write(ref _flushArmed, 0);
        _readSignal.Reset();
        _flushSignal.Reset();
    }

    public void Clear() => H1HeaderData?.Clear();

    public bool IsClosed => Volatile.Read(ref _closed) != 0;

    // ============================ READ ============================

    public ValueTask<bool> ReadAsync()
    {
        if (Volatile.Read(ref _pending) == 1)
        {
            Volatile.Write(ref _pending, 0);
            return new ValueTask<bool>(Volatile.Read(ref _closed) != 0);
        }
        if (Volatile.Read(ref _closed) != 0)
            return new ValueTask<bool>(true);

        _readSignal.Reset();
        Volatile.Write(ref _armed, 1);

        // Lost-wakeup guard: data/close may have raced in just before we armed.
        if (Volatile.Read(ref _pending) == 1 || Volatile.Read(ref _closed) != 0)
        {
            Volatile.Write(ref _pending, 0);
            Volatile.Write(ref _armed, 0);
            return new ValueTask<bool>(Volatile.Read(ref _closed) != 0);
        }
        return new ValueTask<bool>(this, _readSignal.Version);
    }

    /// <summary>Worker thread: the fd is readable — wake the handler's ReadAsync.
    /// The worker does NOT recv; the handler calls <see cref="DoRecv"/> itself.</summary>
    public void SignalReadable()
    {
        if (Interlocked.Exchange(ref _armed, 0) == 1)
            _readSignal.SetResult(Volatile.Read(ref _closed) != 0);
        else
            Volatile.Write(ref _pending, 1);
    }

    /// <summary>
    /// Handler thread: drain the socket into <see cref="ReceiveBuffer"/> (edge-triggered:
    /// read until EAGAIN). Because only the handler ever touches the recv buffer, there is
    /// no driver/handler race. Returns false on peer close / hard error.
    /// </summary>
    public bool DoRecv()
    {
        while (true)
        {
            int avail = _inSlabSize - Tail;
            if (avail == 0) return true;   // buffer full — handler must drain it first
            long got = recv(Fd, ReceiveBuffer + Tail, (ulong)avail, 0);
            if (got > 0) { Tail += (int)got; continue; }
            if (got == 0) return false;    // peer closed
            int err = Marshal.GetLastPInvokeError();
            if (err is EAGAIN or EWOULDBLOCK) return true;   // drained
            if (err == EINTR) continue;
            return false;
        }
    }

    // ============================ FLUSH ============================

    public ValueTask FlushAsync()
    {
        FlushResult r = TryFlush();
        if (r == FlushResult.Complete)
            return ValueTask.CompletedTask;
        if (r == FlushResult.Close)
        {
            MarkClosed();
            return ValueTask.CompletedTask;   // Serve observes IsClosed and exits
        }

        // Partial / EAGAIN — wait for the worker to drain EPOLLOUT.
        _flushSignal.Reset();
        Volatile.Write(ref _flushArmed, 1);
        ArmEpollOut();
        return new ValueTask(this, _flushSignal.Version);
    }

    /// <summary>Non-blocking send of everything staged in <see cref="WriteBuffer"/>.</summary>
    public FlushResult TryFlush()
    {
        while (true)
        {
            long remaining = WriteBuffer.Tail - WriteBuffer.Head;
            if (remaining == 0) { WriteBuffer.Reset(); return FlushResult.Complete; }

            byte* head = WriteBuffer.Ptr + WriteBuffer.Head;
            long n = send(Fd, head, remaining, MSG_NOSIGNAL);
            if (n > 0)
            {
                if (n == remaining) { WriteBuffer.Reset(); return FlushResult.Complete; }
                WriteBuffer.Head += (int)n;
                continue;
            }

            int err = (n == 0) ? EAGAIN : Marshal.GetLastPInvokeError();
            if (err is EAGAIN or EWOULDBLOCK) return FlushResult.Incomplete;
            return FlushResult.Close;
        }
    }

    /// <summary>Worker thread: EPOLLOUT fully drained — wake the handler's FlushAsync.</summary>
    public void CompleteFlush()
    {
        if (Interlocked.Exchange(ref _flushArmed, 0) == 1)
            _flushSignal.SetResult(true);
    }

    // ============================ CLOSE ============================

    public void MarkClosed()
    {
        Volatile.Write(ref _closed, 1);
        if (Interlocked.Exchange(ref _armed, 0) == 1)
            _readSignal.SetResult(true);
        else
            Volatile.Write(ref _pending, 1);

        if (Interlocked.Exchange(ref _flushArmed, 0) == 1)
            _flushSignal.SetResult(true);
    }

    // ========================= epoll arming =========================

    private void ArmEpollOut()
    {
        byte* ev = stackalloc byte[EvSize];
        WriteEpollEvent(ev, EPOLLOUT | EPOLLRDHUP | EPOLLERR | EPOLLHUP | EPOLLET, Fd);
        epoll_ctl(Ep, EPOLL_CTL_MOD, Fd, (IntPtr)ev);
    }

    public void ArmEpollIn()
    {
        byte* ev = stackalloc byte[EvSize];
        WriteEpollEvent(ev, EPOLLIN | EPOLLRDHUP | EPOLLERR | EPOLLHUP | EPOLLET, Fd);
        epoll_ctl(Ep, EPOLL_CTL_MOD, Fd, (IntPtr)ev);
    }

    // ===================== IValueTaskSource<bool> (read) =====================
    bool IValueTaskSource<bool>.GetResult(short token) => _readSignal.GetResult(token);
    ValueTaskSourceStatus IValueTaskSource<bool>.GetStatus(short token) => _readSignal.GetStatus(token);
    void IValueTaskSource<bool>.OnCompleted(Action<object?> continuation, object? state, short token, ValueTaskSourceOnCompletedFlags flags)
        => _readSignal.OnCompleted(continuation, state, token, flags);

    // ======================= IValueTaskSource (flush) =======================
    void IValueTaskSource.GetResult(short token) => _flushSignal.GetResult(token);
    ValueTaskSourceStatus IValueTaskSource.GetStatus(short token) => _flushSignal.GetStatus(token);
    void IValueTaskSource.OnCompleted(Action<object?> continuation, object? state, short token, ValueTaskSourceOnCompletedFlags flags)
        => _flushSignal.OnCompleted(continuation, state, token, flags);

    public void Dispose()
    {
        if (ReceiveBuffer != null)
            NativeMemory.AlignedFree(ReceiveBuffer);
        WriteBuffer.Dispose();
        GC.SuppressFinalize(this);
    }
}
