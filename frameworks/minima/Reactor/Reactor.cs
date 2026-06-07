using System.Collections.Concurrent;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Minima.Utils;
using static Minima.Native;
// ReSharper disable SuggestVarOrType_BuiltInTypes

namespace Minima;

/// <summary>
/// One reactor = one thread + one io_uring + one listening socket (SO_REUSEPORT)
/// + one connection map. The reactor thread is the sole writer of the SQ ring,
/// the kernel-shared buf_ring, and the connection map. Handlers may run on any
/// thread (e.g. resumed by a thread-pool timer after `await Task.Delay(1)`);
/// they reach the reactor only through two MPSC queues (`_returnQ`, `_flushQ`)
/// woken by an `eventfd` registered as a multishot poll in the ring.
/// </summary>
public sealed unsafe partial class Reactor
{
    public readonly int Id;
    public Ring Ring = null!;   // created on the reactor's own thread (DEFER_TASKRUN requires same-thread setup+enter)
    public readonly Dictionary<int,Connection> Connections = new();

    private int _listenFd;
    private readonly ServerConfig _config;
    private readonly ushort _port;
    private readonly uint _ringEntries;
    private readonly bool _incremental;
    private readonly uint RecvBufferSize;

    // CQE user_data layout: kind tag in the high 32 bits, fd in the low 32.
    private const ulong KindAccept = 1UL << 32;
    private const ulong KindRecv   = 2UL << 32;
    private const ulong KindSend   = 3UL << 32;
    private const ulong KindWake   = 4UL << 32;  // eventfd-based cross-thread wake

    // Provided-buffer ring (one per reactor, shared by all its connections).
    private const ushort BgId = 1;
    private readonly uint BufferRingEntries;                // power of two
    private byte*  _bufRing;          // io_uring_buf_ring (kernel-shared)
    private byte*  _bufSlab;          // contiguous slab of recv buffers
    private uint   _bufRingMask;
    private ushort _bufRingTail;

    // Cross-thread wake mechanism: handlers running off-reactor enqueue work
    // into these MPSC queues and `eventfd_write` _wakeFd; a multishot poll on
    // _wakeFd registered with the ring delivers a CQE that wakes the reactor.
    // When the caller is already the reactor thread (the common case — handler
    // resumed inline from an IVTS SetResult), the Enqueue* methods bypass
    // the queue and call the direct op, avoiding 2 syscalls per request.
    private int _wakeFd;
    private int _reactorThreadId;
    private readonly Mpsc<ushort> _returnQ = new(1 << 14);   // 16384 slots
    private readonly Mpsc<int>    _flushQ  = new(1 << 12);   // 4096 slots

    // Teardown handoff: when a connection's refcount hits 0 off-reactor (handler exited
    // on the thread pool), the recycle must run on the reactor (it touches the buf_ring
    // and the reactor-only pool). Connection is a ref type, so this is a ConcurrentQueue
    // rather than the unmanaged Mpsc<T>.
    private readonly ConcurrentQueue<Connection> _recycleQ = new();

    // Connection pool. Reactor-thread-only — accept and teardown both run on
    // this reactor, so a plain Stack<T> is sufficient (no MPMC primitive
    // needed). PoolMax caps the slab footprint per reactor:
    //   PoolMax × WriteSlabSize × ReactorCount = total reserved native memory.
    private readonly int PoolMax;
    private readonly Stack<Connection> _pool;

    // Incremental-mode (IOU_PBUF_RING_INC) sizing. Each connection gets its own
    // ring, so reserved native memory is bounded by:
    //   PoolMax × ConnBufRingEntries × IncRecvBufferSize × ReactorCount.
    // Keep entries small — the point of incremental is that one buffer holds
    // many reads, so you need few of them per connection.
    private readonly int  MaxConnections;       // GID cap (one bgid per active connection)
    private readonly int  ConnBufRingEntries;   // buffers per connection ring
    private readonly uint IncRecvBufferSize;    // bytes per buffer (filled incrementally)

    // Transient io_uring_enter errnos (Linux): interrupted, would-block, busy.
    private const int EINTR  = 4;
    private const int EAGAIN = 11;
    private const int EBUSY  = 16;

    public Reactor(int id, ServerConfig config)
    {
        Id = id;
        _config = config;
        _port = config.Port;
        _ringEntries = config.RingEntries;
        _incremental = config.Incremental;
        RecvBufferSize = (uint)config.RecvBufferSize;
        BufferRingEntries = (uint)config.BufferRingEntries;
        PoolMax = config.PoolMax;
        MaxConnections = config.MaxConnections;
        ConnBufRingEntries = config.ConnBufRingEntries;
        IncRecvBufferSize = (uint)config.IncRecvBufferSize;
        _pool = new Stack<Connection>(config.PoolMax);
    }

    // =========================================================================
    // Buffer ring
    // =========================================================================

    private void InitBufferRing()
    {
        nuint ringBytes = (nuint)BufferRingEntries * 16;
        _bufRing = (byte*)NativeMemory.AlignedAlloc(ringBytes, 4096);
        NativeMemory.Clear(_bufRing, ringBytes);

        nuint slabBytes = BufferRingEntries * (nuint)RecvBufferSize;
        _bufSlab = (byte*)NativeMemory.AlignedAlloc(slabBytes, 64);

        _bufRingMask = BufferRingEntries - 1;

        var reg = new io_uring_buf_reg {
            ring_addr    = (ulong)_bufRing,
            ring_entries = BufferRingEntries,
            bgid         = BgId,
        };

        int ret = io_uring_register(Ring.Fd, IORING_REGISTER_PBUF_RING, &reg, 1);
        if (ret < 0)
        {
            int err = Marshal.GetLastPInvokeError();

            throw new InvalidOperationException($"register pbuf_ring failed: ret={ret} errno={err}");
        }

        // Populate every slot once. Slot 0 overlaps with the ring's tail field
        // at offset 14, but we only write addr/len/bid (offsets 0..13) so tail
        // stays at zero until we set it explicitly.
        for (ushort bid = 0; bid < BufferRingEntries; bid++) {
            byte* slot = _bufRing + (uint)bid * 16;
            *(ulong*)(slot + 0)  = (ulong)(_bufSlab + bid * (nuint)RecvBufferSize);
            *(uint*)(slot + 8)   = RecvBufferSize;
            *(ushort*)(slot + 12) = bid;
        }
        _bufRingTail = (ushort)BufferRingEntries;

        Volatile.Write(ref *(ushort*)(_bufRing + 14), _bufRingTail);
    }

    // Reactor-thread-only: writes the kernel-shared buf_ring tail directly.
    // Off-reactor callers must use EnqueueReturnQ instead.
    internal void ReturnBufferDirect(ushort bid)
    {
        byte* slot = _bufRing + (_bufRingTail & _bufRingMask) * 16;
        *(ulong*)(slot + 0)  = (ulong)(_bufSlab + bid * (nuint)RecvBufferSize);
        *(uint*)(slot + 8)   = RecvBufferSize;
        *(ushort*)(slot + 12) = bid;
        _bufRingTail++;

        Volatile.Write(ref *(ushort*)(_bufRing + 14), _bufRingTail);
    }

    // =========================================================================
    // Cross-thread entry points (safe to call from any thread)
    // =========================================================================

    public void EnqueueReturnQ(ushort bid)
    {
        // Fast path: caller is the reactor thread (handler running inline from
        // an IVTS SetResult). Go straight to the buf_ring — no queue, no syscall.
        if (Environment.CurrentManagedThreadId == _reactorThreadId)
        {
            ReturnBufferDirect(bid);
            return;
        }
        SpinWait sw = default;
        while (!_returnQ.TryEnqueue(bid))
        {
            sw.SpinOnce();
        }
        //WakeFdWrite();
    }

    internal void EnqueueFlush(int fd)
    {
        // Fast path: caller is the reactor thread; write the SQE directly.
        if (Environment.CurrentManagedThreadId == _reactorThreadId)
        {
            if (Connections.TryGetValue(fd, out var conn))
            {
                SubmitSend(fd, conn.WriteBuffer, (uint)conn.WriteInFlight);
            }
            return;
        }
        SpinWait sw = default;
        while (!_flushQ.TryEnqueue(fd))
        {
            sw.SpinOnce();
        }
        WakeFdWrite();
    }
    
    // Called by Connection.DecRef when the refcount hits 0. Teardown must run on the
    // reactor (buf_ring + pool are reactor-owned), so off-reactor callers hand off.
    internal void EnqueueRecycle(Connection conn)
    {
        if (Environment.CurrentManagedThreadId == _reactorThreadId)
        {
            Recycle(conn, conn.ClientFd);
            return;
        }
        _recycleQ.Enqueue(conn);
        WakeFdWrite();
    }

    private void WakeFdWrite()
    {
        ulong v = 1;
        // 8-byte write to eventfd increments its counter; the kernel marks the
        // fd readable, which fires our registered multishot poll's next CQE.
        write(_wakeFd, &v, 8);
    }

    private void DrainReturnQ()
    {
        while (_returnQ.TryDequeue(out ushort bid))
        {
            ReturnBufferDirect(bid);
        }
    }

    private void DrainFlushQ()
    {
        while (_flushQ.TryDequeue(out int fd))
        {
            if (!Connections.TryGetValue(fd, out var conn))
            {
                continue;
            }
            // Connection state was set by FlushAsync; the Enqueue/Dequeue pair
            // establishes the happens-before so WriteInFlight is visible here.
            SubmitSend(fd, conn.WriteBuffer, (uint)conn.WriteInFlight);
        }
    }

    private void DrainRecycleQ()
    {
        while (_recycleQ.TryDequeue(out Connection? conn))
        {
            Recycle(conn, conn.ClientFd);
        }
    }

    private void ArmWakePoll()
    {
        IoUringSqe* sqe = GetSqeOrFlush();
        Unsafe.InitBlockUnaligned(sqe, 0, 64);
        sqe->opcode    = IORING_OP_POLL_ADD;
        sqe->fd        = _wakeFd;
        sqe->op_flags  = POLLIN;                  // poll32_events lives at this offset
        sqe->len       = IORING_POLL_ADD_MULTI;   // multishot — stays armed across CQEs
        sqe->user_data = KindWake | (uint)_wakeFd;
    }

    // =========================================================================
    // Main loop
    // =========================================================================

    public void Run()
    {
        _reactorThreadId = Environment.CurrentManagedThreadId;

        Ring = Ring.Create(_ringEntries);
        _listenFd = OpenReusePortListener(_port);

        if (_incremental)
        {
            InitIncremental();
        }
        else
        {
            InitBufferRing();
        }

        _wakeFd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
        if (_wakeFd < 0)
        {
            throw new InvalidOperationException("eventfd failed");
        }

        Console.WriteLine($"[r{Id}] listening on 0.0.0.0:{_port} (incremental={_incremental})");
        SubmitAcceptMultishot();
        ArmWakePoll();

        if (_incremental)
        {
            LoopIncremental();
        }
        else
        {
            LoopShared();
        }

        close(_listenFd);
        close(_wakeFd);
        Ring.Dispose();
    }

    private void LoopShared()
    {
        while (true)
        {
            // Drain MPSC queues from off-reactor handlers. Cheap when empty.
            DrainReturnQ();
            DrainFlushQ();
            DrainRecycleQ();

            int rc = Ring.SubmitAndWait(1);
            if (rc < 0 && rc != -EINTR && rc != -EAGAIN && rc != -EBUSY)
            {
                Console.Error.WriteLine($"[r{Id}] io_uring_enter failed: {rc}");
                break;
            }

            uint ready = Ring.CqReady();
            for (uint i = 0; i < ready; i++)
            {
                Dispatch(in Ring.CqeAt(i));
            }
            Ring.CqAdvance(ready);
        }
    }

    private void Dispatch(in IoUringCqe cqe)
    {
        ulong kind = cqe.user_data & 0xffffffff_00000000UL;
        int   fd   = (int)(cqe.user_data & 0xffffffffUL);
        bool  more = (cqe.flags & IORING_CQE_F_MORE) != 0;

        if (kind == KindWake)
        {
            // Drain the eventfd counter so the next write re-triggers POLLIN
            // (multishot poll is edge-triggered on the user_space side).
            ulong drain;
            read(_wakeFd, &drain, 8);
            // The actual queue drains happen at the top of the next loop
            // iteration — nothing else to do here.
            if (!more)
            {
                ArmWakePoll();
            }
            return;
        }

        if (kind == KindAccept)
        {
            if (cqe.res >= 0)
            {
                int clientFd = cqe.res;
                SetNoDelay(clientFd);
                Connection conn = _pool.TryPop(out var pooled)
                    ? pooled.SetFd(clientFd)
                    : new Connection(this, clientFd, _config.WriteSlabSize);
                Connections[clientFd] = conn;
                conn.InitRefs();
                SubmitRecvMultishot(clientFd);

                _ = _config.UsePipe
                    ? Handler.HandlePipeAsync(this, conn)
                    : Handler.HandleAsync(this, conn);
            }
            else
            {
                Console.Error.WriteLine($"[r{Id}] accept error: {cqe.res}");
            }
            // Multishot accept stays armed; only re-arm if the kernel terminated it.
            if (!more)
            {
                SubmitAcceptMultishot();
            }
        }
        else if (kind == KindRecv)
        {
            bool   hasBuf = (cqe.flags & IORING_CQE_F_BUFFER) != 0;
            ushort bid    = hasBuf ? (ushort)(cqe.flags >> IORING_CQE_BUFFER_SHIFT) : (ushort)0;

            if (cqe.res <= 0)
            {
                // Peer EOF or recv error — reactor owns teardown.
                if (hasBuf)
                {
                    ReturnBufferDirect(bid);
                }
                if (Connections.Remove(fd, out var dyingConn))
                {
                    dyingConn.MarkClosed();   // signal the handler to exit
                    dyingConn.DecRef();       // release the reactor's ref; teardown at refs==0
                }
                return;
            }

            if (!Connections.TryGetValue(fd, out var conn))
            {
                // Straggler buffer for an already-closed connection.
                if (hasBuf)
                {
                    ReturnBufferDirect(bid);
                }
                return;
            }

            byte* ptr = hasBuf ? _bufSlab + (nuint)bid * (nuint)RecvBufferSize : null;
            conn.Complete(cqe.res, bid, hasBuf, ptr);

            if (!more)
            {
                SubmitRecvMultishot(fd);
            }
        }
        else if (kind == KindSend)
        {
            if (!Connections.TryGetValue(fd, out var conn))
            {
                return;
            }
            if (cqe.res <= 0)
            {
                // Send error — release the reactor's ref; teardown when the handler exits too.
                Connections.Remove(fd);
                conn.MarkClosed();
                conn.DecRef();
                return;
            }
            conn.WriteHead += cqe.res;
            if (conn.WriteHead < conn.WriteInFlight)
            {
                // Partial send: resubmit the remainder.
                SubmitSend(fd, conn.WriteBuffer + conn.WriteHead, (uint)(conn.WriteInFlight - conn.WriteHead));
                return;
            }
            // Full target ack'd — resets buffer state and signals the awaiter.
            conn.CompleteFlush();
        }
    }

    // =========================================================================
    // SQE producers (reactor-thread-only — Connection.FlushAsync hands off via
    // EnqueueFlush, which DrainFlushQ turns into SubmitSend on this thread)
    // =========================================================================

    private IoUringSqe* GetSqeOrFlush()
    {
        IoUringSqe* sqe = Ring.GetSqe();
        if (sqe != null)
        {
            return sqe;
        }

        Ring.SubmitAndWait(0);
        sqe = Ring.GetSqe();

        if (sqe == null)
        {
            throw new InvalidOperationException("SQ full after flush");
        }

        return sqe;
    }

    private void SubmitAcceptMultishot()
    {
        IoUringSqe* sqe = GetSqeOrFlush();
        Unsafe.InitBlockUnaligned(sqe, 0, 64);
        sqe->opcode    = IORING_OP_ACCEPT;
        sqe->ioprio    = IORING_ACCEPT_MULTISHOT;
        sqe->fd        = _listenFd;
        sqe->user_data = KindAccept | (uint)_listenFd;
    }

    private void SubmitRecvMultishot(int fd) => SubmitRecvMultishot(fd, BgId);

    private void SubmitRecvMultishot(int fd, ushort bgid)
    {
        IoUringSqe* sqe = GetSqeOrFlush();
        Unsafe.InitBlockUnaligned(sqe, 0, 64);
        sqe->opcode    = IORING_OP_RECV;
        sqe->flags     = IOSQE_BUFFER_SELECT;
        sqe->ioprio    = IORING_RECV_MULTISHOT;
        sqe->fd        = fd;
        sqe->buf_index = bgid;          // buffer-group id (shared BgId, or per-conn in incremental)
        sqe->user_data = KindRecv | (uint)fd;
    }

    private void SubmitSend(int fd, byte* buf, uint len)
    {
        IoUringSqe* sqe = GetSqeOrFlush();
        Unsafe.InitBlockUnaligned(sqe, 0, 64);
        sqe->opcode    = IORING_OP_SEND;
        sqe->fd        = fd;
        sqe->addr      = (ulong)buf;
        sqe->len       = len;
        sqe->user_data = KindSend | (uint)fd;
    }

    private void Recycle(Connection conn, int fd)
    {
        // Wake awaiters, drain in-flight buffers, close the fd, reset state,
        // and either push the Connection back to the pool or free its native
        // WriteBuffer if the pool is full.
        conn.MarkClosed();
        if (_incremental)
        {
            // The per-connection ring is freed wholesale; no per-buffer return.
            // Clear() empties the SPSC ring (leftover slices discarded).
            TeardownConnectionBufRing(conn);
        }
        else
        {
            conn.DrainRecv();   // return leftover buffers to the shared ring
        }
        close(fd);
        conn.Clear();

        if (_pool.Count < PoolMax)
        {
            _pool.Push(conn);
        }
        else
        {
            conn.Dispose();
        }
    }

    // Disable Nagle on an accepted connection. Must be set per-accepted-socket,
    // not on the listener — TCP_NODELAY doesn't reliably inherit across accept,
    // which is why zerg/terraform/rtr all set it on the client fd, not the listener.
    private static void SetNoDelay(int fd)
    {
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(int));
    }

    private static int OpenReusePortListener(ushort port)
    {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0)
        {
            throw new InvalidOperationException($"socket failed: {fd}");
        }

        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(int));
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(int));

        sockaddr_in addr = default;
        addr.sin_family      = AF_INET;
        addr.sin_port        = Htons(port);
        addr.sin_addr.s_addr = 0; // 0.0.0.0

        if (bind(fd, &addr, (uint)sizeof(sockaddr_in)) < 0)
        {
            throw new InvalidOperationException("bind failed");
        }

        if (listen(fd, 128) < 0)
        {
            throw new InvalidOperationException("listen failed");
        }

        return fd;
    }
}
