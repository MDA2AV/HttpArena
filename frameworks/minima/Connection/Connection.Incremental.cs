using System.Runtime.InteropServices;
using Minima.Utils;
// ReSharper disable SuggestVarOrType_BuiltInTypes

namespace Minima;

/// <summary>
/// Incremental-mode (IOU_PBUF_RING_INC) per-connection buffer-ring state.
/// Each connection owns its own ring + slab; one buffer accumulates this
/// connection's byte stream across many recvs. The reactor (Reactor.Incremental)
/// drives setup/teardown and the refcounted recycle; this partial just holds the
/// state and routes a handler return to the right reactor entry point.
///
/// All of these stay allocated across pool reuse and are freed in Dispose().
/// </summary>
public sealed unsafe partial class Connection
{
    internal byte*   BufRing;          // kernel-shared ring control area
    internal byte*   BufSlab;          // this connection's recv slab
    internal ushort  Bgid;
    internal uint    BufRingMask;
    internal int     BufRingEntries;
    internal bool    IncrementalMode;

    internal int[]?  CumOffset;        // per-bid: byte offset where the next slice begins
    internal int[]?  RefCount;         // per-bid: outstanding handler refs
    internal bool[]? KernelDone;       // per-bid: kernel finished appending (no F_BUF_MORE)

    internal int Generation => Volatile.Read(ref _generation); 

    /// <summary>
    /// Called by the handler to hand a consumed recv buffer back. Routes by mode:
    /// incremental returns carry (fd, gen, bid) for refcounted recycle; the shared
    /// path returns the bare bid to the reactor's single buf_ring.
    /// </summary>
    public void ReturnBuffer(in SpscRecvRing.Item item)
    {
        if (IncrementalMode)
        {
            _reactor.EnqueueReturnQIncremental(ClientFd, item.Gen, item.Bid);
        }
        else
        {
            _reactor.EnqueueReturnQ(item.Bid);
        }
    }

    private void DisposeIncremental()
    {
        if (BufRing != null)
        {
            NativeMemory.AlignedFree(BufRing);
            BufRing = null;
        }
        if (BufSlab != null)
        {
            NativeMemory.AlignedFree(BufSlab);
            BufSlab = null;
        }
    }
}
