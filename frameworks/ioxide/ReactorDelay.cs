using System.Diagnostics;
using System.Threading.Tasks.Sources;

using ioxide;

namespace IoxideArena;

/// <summary>
/// A wait that keeps the request on the reactor that owns it and allocates
/// nothing per request.
///
/// The async profile answers <c>GET /delay/{ms}</c> after the milliseconds named
/// in the path, with 64,000 connections in flight, so every one of them is a
/// pending timer.
///
/// <c>Task.Delay</c> was measured against this and matched it on throughput, so
/// the thread-pool hop its continuation takes is not what costs. What costs is
/// the allocation. Every request that allocates a completion object feeds the
/// collector, and at this rate that was 354 MB/s, a gen0 collection roughly
/// twice a second, and an average pause of 12.5ms. A 12.5ms stop-the-world
/// pause against a 15ms delay means practically every deadline in the process
/// expires while it is frozen, and the first drain afterwards completes a whole
/// reactor's worth of connections in one batch - 2,100 of them, measured. That
/// is the tail this profile reports, and none of it is the waiting.
///
/// So the completion is reused instead. A connection has at most one delay
/// outstanding, because the handler awaits it before reading again, so one
/// <see cref="DelaySource"/> per session covers every request that connection
/// will ever make. The rest of ioxide's request path already allocates nothing -
/// 89.3M baseline requests moved the heap by 0 MB - and now the delay path
/// matches it.
///
/// What ioxide gives us is <see cref="Reactor.ScheduleOnReactor"/>, which runs a
/// callback on a specific reactor thread. That solves affinity but not timing,
/// and posting one callback per expiry would be 4M cross-thread posts a second
/// at this profile's load.
///
/// So the posts are batched instead. One thread for the whole process ticks and
/// asks each reactor to drain, and the reactor pops everything now due in one
/// pass. That is ~64 posts per tick rather than one per request, and the pending
/// timers themselves live in thread-static state touched only by the reactor
/// that owns them, so the hot path takes no lock at all.
///
/// The honest limitation: this is a userspace tick, not a kernel timer.
/// <c>IORING_OP_TIMEOUT</c> is the right primitive - the kernel holds the
/// deadline and completes it on the ring, on this thread, with no second thread
/// anywhere - but ioxide exposes no way to submit one. See MDA2AV/ioxide#212.
/// </summary>
internal static class ReactorDelay
{
    // The tick is a fallback now, not the mechanism, so it sleeps rather than
    // spins. It used to hold a 250us schedule with SpinOnce(-1), which never
    // yields: the thread burned 87% of a core doing that, and on a box where
    // reactors are pinned it was taking most of a core away from one of them.
    // A millisecond of scheduler granularity is plenty for the only case that
    // still needs it, and validation asserts a lower bound on the wait, so
    // overshoot cannot fail an entry.
    private const int TickMilliseconds = 1;

    private static readonly List<Reactor> Reactors = [];
    // Last time each reactor drained itself, by shard index. The tick reads this
    // to skip reactors that do not need it.
    private static long[] _selfDrain = [];
    private static readonly Lock ReactorsGate = new();
    private static readonly Action<object?> DrainCallback = _ => Drain();
    private static int _started;

    // Touched only by the reactor thread that owns it: the handler parks a
    // request from this thread, and the drain runs on this thread too.
    [ThreadStatic] private static PriorityQueue<DelaySource, long>? _pending;
    [ThreadStatic] private static int _shard;
    // Completing a timer runs its continuation inline, and that continuation
    // re-enters the handler loop, which drains again. Without this the stack
    // would nest one connection's resume inside another's for as deep as the
    // queue happens to be.
    [ThreadStatic] private static bool _draining;

    /// <summary>
    /// Completes after <paramref name="ms"/>, on this reactor's thread, reusing
    /// <paramref name="source"/> so the wait costs no allocation.
    /// </summary>
    public static ValueTask Delay(Reactor reactor, int ms, DelaySource source)
    {
        if (ms <= 0) return ValueTask.CompletedTask;

        // Registering a reactor is permanent and per thread, so it belongs on the
        // first call from that thread and nowhere else. It used to run on every
        // call, and the process-global lock it takes - several million times a
        // second, contended by every reactor at once - was the profile's ceiling:
        // throughput flattened at a number that did not move when the delay got
        // shorter, and the box sat at a third of its CPU because the reactor
        // threads were queued on the lock rather than serving. An empty queue is
        // exactly the "first call on this thread" signal, so it gates both.
        var q = _pending;
        if (q is null)
        {
            q = _pending = new PriorityQueue<DelaySource, long>();
            _shard = reactor.ShardIndex;
            Register(reactor);
        }

        // Continuations run synchronously on whichever thread completes the
        // source, and that is deliberately the reactor thread - the whole point
        // is that the connection never leaves it.
        q.Enqueue(source, Stopwatch.GetTimestamp() + (long)(ms * (Stopwatch.Frequency / 1000.0)));
        return source.Wait();
    }

    private static void Register(Reactor reactor)
    {
        lock (ReactorsGate)
        {
            if (_selfDrain.Length < reactor.ShardCount)
            {
                _selfDrain = new long[reactor.ShardCount];
            }
            if (!Reactors.Contains(reactor))
            {
                Reactors.Add(reactor);
            }
        }
        if (Interlocked.Exchange(ref _started, 1) == 0)
        {
            // One thread for the process, not a pool thread: it must not be
            // delayed behind unrelated work, and it must not grow with load.
            var t = new Thread(TickLoop) { IsBackground = true, Name = "reactor-delay" };
            t.Start();
        }
    }

    private static void TickLoop()
    {
        long tickTicks = Stopwatch.Frequency / 1000L * TickMilliseconds;
        while (true)
        {
            Thread.Sleep(TickMilliseconds);

            long now = Stopwatch.GetTimestamp();
            lock (ReactorsGate)
            {
                for (int i = 0; i < Reactors.Count; i++)
                {
                    Reactor r = Reactors[i];
                    // A reactor serving traffic drains itself on every pass of the
                    // handler loop, and posting to it would be pure cross-thread
                    // cost. Only a reactor whose connections are all parked - so
                    // nothing is looping to drain them - still needs the tick.
                    if (now - Volatile.Read(ref _selfDrain[r.ShardIndex]) < tickTicks)
                    {
                        continue;
                    }
                    try
                    {
                        r.ScheduleOnReactor(DrainCallback, null);
                    }
                    catch
                    {
                        // A reactor shutting down is not this thread's problem.
                    }
                }
            }
        }
    }

    /// <summary>
    /// Drain from the reactor's own hot path, called once per pass of the handler
    /// loop.
    ///
    /// This is what the tick used to be for, and it is strictly better: it costs
    /// a thread-static read and a peek, it runs on the reactor that owns the
    /// timers, and under load it happens far more often than any tick would. At
    /// this profile's rate each reactor passes through here around 50,000 times a
    /// second, where the fallback tick fires 1,000 times.
    /// </summary>
    public static void DrainDue()
    {
        if (_pending is null || _pending.Count == 0) return;
        Volatile.Write(ref _selfDrain[_shard], Stopwatch.GetTimestamp());
        Drain();
    }

    /// <summary>Runs on a reactor thread: complete everything now due.</summary>
    private static void Drain()
    {
        // Re-entered from a continuation this drain just completed.
        if (_draining) return;

        PriorityQueue<DelaySource, long>? q = _pending;
        if (q is null || q.Count == 0) return;

        _draining = true;
        try
        {
            long now = Stopwatch.GetTimestamp();
            while (q.TryPeek(out _, out long deadline) && deadline <= now)
            {
                q.Dequeue().Complete();
            }
        }
        finally
        {
            _draining = false;
        }
    }
}

/// <summary>
/// One reusable completion, owned by a connection's session.
///
/// <see cref="ManualResetValueTaskSourceCore{T}"/> is the allocation-free half of
/// a <c>TaskCompletionSource</c>: it holds the continuation and a version token
/// rather than handing out a fresh <c>Task</c>. Resetting it after the awaiter
/// has taken its result bumps that token, which is what makes the next wait on
/// the same object a different wait and not a stale one.
///
/// Safe to reuse only because a connection never has two delays in flight: the
/// handler awaits one before it reads the next request.
/// </summary>
internal sealed class DelaySource : IValueTaskSource
{
    // Continuations run inline on the completing thread, which is the reactor
    // thread - the same affinity the Task version had.
    private ManualResetValueTaskSourceCore<bool> _core = new() { RunContinuationsAsynchronously = false };

    public ValueTask Wait() => new(this, _core.Version);

    public void Complete() => _core.SetResult(true);

    public void GetResult(short token)
    {
        _core.GetResult(token);
        // Re-arm for this connection's next request. Has to happen after the
        // result is taken, or the token the awaiter is holding stops matching.
        _core.Reset();
    }

    public ValueTaskSourceStatus GetStatus(short token) => _core.GetStatus(token);

    public void OnCompleted(Action<object?> continuation, object? state, short token, ValueTaskSourceOnCompletedFlags flags)
        => _core.OnCompleted(continuation, state, token, flags);
}
