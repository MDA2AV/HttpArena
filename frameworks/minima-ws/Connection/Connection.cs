using System.Runtime.InteropServices;
using Minima.Utils;

namespace Minima;

public sealed unsafe partial class Connection 
{
    private readonly Reactor _reactor;

    public int ClientFd { get; private set; }

    // Bumped on Clear(); the low 16 bits are used as the IVTS token so stale
    // awaiters can be detected after pool reuse.
    private int _generation;

    // Refcount: the connection has two owners — the reactor (recv side) and the
    // handler (which may run off-reactor). Init to 2 on accept; each owner DecRef's
    // when done; teardown (Recycle) runs only at refs==0, so a connection is never
    // recycled or pool-reused while a handler is still in flight on another thread.
    private int _refs;

    public Connection(Reactor reactor, int fd, int writeSlabSize = 1024 * 16)
    {
        _reactor = reactor;
        ClientFd = fd;
        _writeSlabSize = writeSlabSize;
        WriteBuffer = (byte*)NativeMemory.AlignedAlloc((nuint)writeSlabSize, 64);
        
        _manager = new UnmanagedMemoryManager(WriteBuffer, writeSlabSize);
    }
    
    // =========================================================================
    // Pool lifecycle — invoked from Reactor.Dispatch's recv/send error paths.
    // Reactor-thread only.
    //
    //   teardown:  MarkClosed()  → wake awaiters with closed=1
    //              DrainRecv()   → return any in-flight buf_ring items
    //              close(fd)
    //              Clear()       → reset state, bump _generation
    //              push to pool, OR Dispose() if pool is full
    // =========================================================================
    
    public void MarkClosed()
    {
        Volatile.Write(ref _closed, 1);

        if (Interlocked.Exchange(ref _armed, 0) == 1)
        {
            _readSignal.SetResult(new RecvSnapshot(_recv.SnapshotTail(), isClosed: true));
        }
        else
        {
            Volatile.Write(ref _pending, 1);
        }

        if (Interlocked.Exchange(ref _flushArmed, 0) == 1)
        {
            Volatile.Write(ref _flushInProgress, 0);
            _flushSignal.SetResult(true);
        }
    }

    // Init to 2 (reactor + handler) at accept.
    internal void InitRefs() => Volatile.Write(ref _refs, 2);

    // Release one owner's ref. Whoever drives it to 0 hands the connection to the
    // reactor for teardown (close + Clear + pool) — never recycled before both done.
    internal void DecRef()
    {
        if (Interlocked.Decrement(ref _refs) == 0)
        {
            _reactor.EnqueueRecycle(this);
        }
    }

    internal void Clear()
    {
        // Bump generation first — readers of IVTS plumbing observe this via
        // Volatile.Read and stale tokens get RecvSnapshot.Closed() / no-op.
        Interlocked.Increment(ref _generation);

        Volatile.Write(ref _armed, 0);
        Volatile.Write(ref _pending, 0);
        Volatile.Write(ref _closed, 0);
        Volatile.Write(ref _flushArmed, 0);
        Volatile.Write(ref _flushInProgress, 0);

        WriteHead = 0;
        WriteTail = 0;
        WriteInFlight = 0;

        _readSignal.Reset();
        _flushSignal.Reset();

        _recv.Reset();             // discard any leftover SPSC items
        IncrementalMode = false;   // per-conn ring (if any) was torn down before Clear
    }

    public void Dispose()
    {
        if (WriteBuffer != null)
        {
            NativeMemory.AlignedFree(WriteBuffer);
            WriteBuffer = null;
        }
        DisposeIncremental();
    }
}