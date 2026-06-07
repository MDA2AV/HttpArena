using System.Threading.Tasks.Sources;
using Minima.Utils;

// ReSharper disable SuggestVarOrType_BuiltInTypes

namespace Minima;

/// <summary>
/// Per-connection state. The handler may run on any thread (e.g. resumed by
/// a thread-pool timer); reactor-only side effects are funnelled through the
/// MPSC queues on `Reactor`. Coordination uses Interlocked.Exchange on the
/// arm flags and a sticky `_pending` to close the lost-wakeup race.
///
/// Lifetime is pool-managed: the reactor pops a Connection on accept (or new
/// one if pool is empty), and pushes it back on teardown after `Clear()`. The
/// `_generation` field is bumped on each `Clear` so stale `ValueTask` tokens
/// from a previous connection life are detectable and return `Closed()`
/// instead of leaking the new tenant's state.
/// </summary>
public sealed unsafe partial class Connection : IValueTaskSource<RecvSnapshot>
{
    internal Connection SetFd(int fd)
    {
        ClientFd = fd;
        return this;
    }

    private ManualResetValueTaskSourceCore<RecvSnapshot> _readSignal = new()
    {
        RunContinuationsAsynchronously = false,
    };
    private int _armed;
    private int _pending;
    private int _closed;

    private readonly SpscRecvRing _recv = new(capacityPow2: 16);

    public ValueTask<RecvSnapshot> ReadAsync()
    {
        if (!_recv.IsEmpty() || Volatile.Read(ref _pending) == 1)
        {
            Volatile.Write(ref _pending, 0);
            return new ValueTask<RecvSnapshot>(
                new RecvSnapshot(_recv.SnapshotTail(), Volatile.Read(ref _closed) != 0));
        }

        if (Volatile.Read(ref _closed) != 0)
        {
            return new ValueTask<RecvSnapshot>(RecvSnapshot.Closed());
        }

        if (Interlocked.Exchange(ref _armed, 1) == 1)
        {
            throw new InvalidOperationException("ReadAsync already armed.");
        }

        // Snapshot the generation as the IVTS token so a future Clear() can
        // invalidate this awaiter if the connection gets pool-recycled.
        int gen = Volatile.Read(ref _generation);

        // Race recovery: re-check between arming and returning the IVTS task.
        if (!_recv.IsEmpty() || Volatile.Read(ref _pending) == 1 || Volatile.Read(ref _closed) != 0)
        {
            Volatile.Write(ref _pending, 0);
            Interlocked.Exchange(ref _armed, 0);
            
            return new ValueTask<RecvSnapshot>(
                new RecvSnapshot(_recv.SnapshotTail(), Volatile.Read(ref _closed) != 0));
        }

        return new ValueTask<RecvSnapshot>(this, (short)gen);
    }

    public bool TryGetItem(in RecvSnapshot snap, out SpscRecvRing.Item item)
        => _recv.TryDequeueUntil(snap.Tail, out item);

    public void ResetRead() => _readSignal.Reset();

    public void Complete(int res, ushort bid, bool hasBuffer, byte* ptr)
    {
        if (!_recv.TryEnqueue(new SpscRecvRing.Item
                 {
                     Ptr = ptr,
                     Bid = bid,
                     Len = res,
                     HasBuffer = hasBuffer,
                     Gen = (ushort)Volatile.Read(ref _generation)
                 }))
        {
            Console.Error.WriteLine("[conn] recv queue overflow.");
            if (hasBuffer)
            {
                _reactor.ReturnBufferDirect(bid);
            }
            Volatile.Write(ref _closed, 1);
        }

        if (Interlocked.Exchange(ref _armed, 0) == 1)
        {
            _readSignal.SetResult(new RecvSnapshot(_recv.SnapshotTail(), Volatile.Read(ref _closed) != 0));
        }
        else
        {
            Volatile.Write(ref _pending, 1);
        }
    }
    
    internal void DrainRecv()
    {
        // Return any buffer IDs still sitting in the SPSC ring (handler exited
        // before draining them, or a recv arrived after _closed was set).
        while (_recv.TryDequeue(out SpscRecvRing.Item item))
        {
            if (item.HasBuffer)
            {
                _reactor.ReturnBufferDirect(item.Bid);
            }
        }
    }

    // =========================================================================
    // IValueTaskSource plumbing — token (= snapshot of `_generation` at await
    // time) is compared against the current `_generation` to detect stale
    // awaiters from before a Clear()/pool reuse. Stale awaiters get a
    // sentinel result rather than the new tenant's state.
    //
    // For the actual IVTS dispatch we pass `_readSignal.Version` /
    // `_flushSignal.Version` to the underlying core (not `token`) because the
    // core's version is bumped by ResetRead/CompleteFlush mid-life and is
    // unrelated to the cross-life generation guard.
    // =========================================================================

    RecvSnapshot IValueTaskSource<RecvSnapshot>.GetResult(short token)
    {
        if (token != (short)Volatile.Read(ref _generation))
        {
            return RecvSnapshot.Closed();
        }
        
        return _readSignal.GetResult(_readSignal.Version);
    }

    ValueTaskSourceStatus IValueTaskSource<RecvSnapshot>.GetStatus(short token)
    {
        if (token != (short)Volatile.Read(ref _generation))
        {
            return ValueTaskSourceStatus.Succeeded;
        }
        
        return _readSignal.GetStatus(_readSignal.Version);
    }

    void IValueTaskSource<RecvSnapshot>.OnCompleted(Action<object?> continuation, object? state, short token, ValueTaskSourceOnCompletedFlags flags)
    {
        if (token != (short)Volatile.Read(ref _generation))
        {
            // Stale — run the continuation now so the awaiter unblocks and
            // gets RecvSnapshot.Closed() from GetResult.
            continuation(state);
            
            return;
        }
        
        _readSignal.OnCompleted(continuation, state, _readSignal.Version, flags);
    }
}
