using System.Diagnostics;
using System.Runtime.InteropServices;
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

    // IOXIDE_DELAY_MODE=ring parks each wait on a timerfd submitted to the
    // reactor's own ring, the way ioxide.pg parks on the Postgres socket.
    // SubmitRead on a pollable fd gets there without IORING_OP_TIMEOUT, which
    // ioxide does not expose (MDA2AV/ioxide#212): io_uring arms a poll
    // internally rather than handing the read to a worker thread.
    //
    // It is the default because it measured better on the hardware the profile is
    // scored on, and the reason it looked worse before is worth keeping.
    //
    // A socket read is I/O the connection has to do regardless, so the ring is
    // free for it. A timer is not: this costs a timerfd_settime syscall plus an
    // SQE and a CQE per request. That is real CPU, and on a box with no CPU to
    // spare it can only come out of throughput. The 32-reactor box it was first
    // measured on sat at 0.8% idle with the load generator on it, so the extra
    // cost showed up as a loss and the tick won there:
    //
    //   ring  1.50M rps  2007% cpu       tick  1.58M rps  1765% cpu
    //
    // The bench box has 6400% available and the tick was using 3435% of it, so
    // there the same trade buys something instead. At 16,000 connections and 5ms:
    //
    //   tick  1,842,424 rps  3435% cpu
    //   ring  2,462,698 rps  5831% cpu   avg 6.48ms  p99 9.91ms  p99.9 16.50ms
    //
    // 34% more throughput for 70% more CPU, and 1.48ms of overhead on a 5ms wait.
    // Handing each deadline to the kernel keeps the work flowing continuously
    // where the tick completes timers only when a drain runs, which is what was
    // leaving the reactors idle. The trade is only available where there is spare
    // CPU to spend, so this is worth re-reading if the profile or the hardware
    // changes again.
    //
    // IOXIDE_DELAY_MODE=tick selects the other path.
    // IOXIDE_DELAY_MODE=queue: one timerfd for the whole reactor rather than one per
    // request, armed to the earliest deadline it is holding. This is how Node and Bun
    // do it - the deadline goes into the wait the event loop was making anyway - and
    // it is the only one of the three that neither syscalls per request nor leaves the
    // reactor asleep past a deadline. With ~13 waits coming due together that is one
    // arming per 13 requests instead of 13 armings.
    private static readonly bool UseQueueTimer =
        Environment.GetEnvironmentVariable("IOXIDE_DELAY_MODE") is not ("ring" or "tick");

    private static readonly bool UseRingTimer =
        Environment.GetEnvironmentVariable("IOXIDE_DELAY_MODE") != "tick";

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

        // The ring holds the deadline itself: no tick, no drain, no second
        // thread. Everything below this line is the fallback for when it is off.
        if (UseQueueTimer) return ReactorTimer.Park(reactor, source, ms);
        if (UseRingTimer) return source.WaitOnRing(reactor, ms);

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
                q.Dequeue().Fire();
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
internal sealed class DelaySource : IValueTaskSource, IRingCompletion
{
    private const int ClockMonotonic = 1;
    private const int TfdNonblock = 0x800;
    private const int TfdCloexec = 0x80000;

    [DllImport("libc", SetLastError = true)]
    private static extern int timerfd_create(int clockid, int flags);

    [DllImport("libc", SetLastError = true)]
    private static extern unsafe int timerfd_settime(int fd, int flags, long* newValue, long* oldValue);

    [DllImport("libc", SetLastError = true)]
    private static extern int close(int fd);

    // Created on this connection's first delay and re-armed for every one after,
    // so a delay costs a settime and an SQE - no allocation, no timer object.
    private int _fd = -1;
    private IntPtr _buf;      // the 8-byte expiration count the read returns
    private Reactor? _reactor;
    private long _deadline;   // when this wait is actually allowed to end

    /// <summary>Arms the timer and parks on it through the reactor's ring.</summary>
    public unsafe ValueTask WaitOnRing(Reactor reactor, int ms)
    {
        if (_fd < 0)
        {
            _fd = timerfd_create(ClockMonotonic, TfdNonblock | TfdCloexec);
            if (_fd < 0) throw new InvalidOperationException($"timerfd_create failed, errno {Marshal.GetLastPInvokeError()}");
            _buf = Marshal.AllocHGlobal(8);
        }

        // itimerspec is four longs: interval sec/nsec then value sec/nsec. A
        // zero interval makes it one-shot.
        long* spec = stackalloc long[4];
        spec[0] = 0;
        spec[1] = 0;
        spec[2] = ms / 1000;
        spec[3] = (long)(ms % 1000) * 1_000_000L;
        if (timerfd_settime(_fd, 0, spec, null) < 0)
        {
            throw new InvalidOperationException($"timerfd_settime failed, errno {Marshal.GetLastPInvokeError()}");
        }

        _reactor = reactor;
        _deadline = Stopwatch.GetTimestamp() + (long)(ms * (Stopwatch.Frequency / 1000.0));

        short token = _core.Version;
        reactor.SubmitRead(_fd, _buf, 8, 0, this);
        return new ValueTask(this, token);
    }

    /// <summary>
    /// The ring completion. A completion is not on its own proof that this
    /// connection's wait is over, so the deadline decides.
    ///
    /// Two ways it can arrive early. The fd is non-blocking, so a read the
    /// kernel does not arm a poll for returns -EAGAIN immediately. And the fd is
    /// reused across every request on the connection, so a read can pick up an
    /// expiration left behind by an earlier one and return a perfectly valid 8
    /// bytes for a timer that already fired. Measured under load, the second is
    /// the one that actually happens: about 0.1% of waits, the worst of them
    /// resuming 14.9ms into a 15ms delay, which is the whole wait skipped.
    ///
    /// Resuming there would answer before the profile's contract allows and
    /// quietly inflate the number, so an early completion goes back on the ring
    /// instead. It costs a comparison on a path that is already a syscall.
    /// </summary>
    public void Complete(int result)
    {
        long now = Stopwatch.GetTimestamp();
        if (now < _deadline)
        {
            _reactor!.SubmitRead(_fd, _buf, 8, 0, this);
            return;
        }

        _core.SetResult(true);
    }

    /// <summary>Releases the timer. Called when the connection is finished.</summary>
    public void Dispose()
    {
        if (_fd >= 0)
        {
            close(_fd);
            _fd = -1;
        }
        if (_buf != IntPtr.Zero)
        {
            Marshal.FreeHGlobal(_buf);
            _buf = IntPtr.Zero;
        }
    }

    // Continuations run inline on the completing thread, which is the reactor
    // thread - the same affinity the Task version had.
    private ManualResetValueTaskSourceCore<bool> _core = new() { RunContinuationsAsynchronously = false };

    public ValueTask Wait() => new(this, _core.Version);

    /// <summary>Completed by the drain, when the fallback tick path is in use.</summary>
    public void Fire() => _core.SetResult(true);

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

/// <summary>
/// One timerfd per reactor, armed to the earliest deadline that reactor is holding.
///
/// The per-request timerfd costs a settime, an SQE and a CQE every time anyone waits.
/// The tick costs nothing per request but only completes a timer when something else
/// happens to wake the reactor, which is what left it idle with deadlines already
/// passed. This is the third option and the one an event loop normally takes: keep the
/// deadlines in a queue, and hold a single timer set to the front of it.
///
/// Everything here is thread-static, so a reactor touches only its own queue and its
/// own timer and nothing is shared between them.
/// </summary>
internal static class ReactorTimer
{
    private const int ClockMonotonic = 1;
    private const int TfdNonblock = 0x800;
    private const int TfdCloexec = 0x80000;

    [DllImport("libc", SetLastError = true)]
    private static extern int timerfd_create(int clockid, int flags);

    [DllImport("libc", SetLastError = true)]
    private static extern unsafe int timerfd_settime(int fd, int flags, long* newValue, long* oldValue);

    [ThreadStatic] private static PriorityQueue<DelaySource, long>? _queue;
    [ThreadStatic] private static int _fd;
    [ThreadStatic] private static IntPtr _buf;
    [ThreadStatic] private static long _armedFor;      // the deadline the timerfd currently holds
    [ThreadStatic] private static bool _readOutstanding;
    [ThreadStatic] private static Completion? _completion;

    /// <summary>Queues the wait and makes sure the reactor's timer covers it.</summary>
    public static ValueTask Park(Reactor reactor, DelaySource source, int ms)
    {
        PriorityQueue<DelaySource, long>? q = _queue;
        if (q is null)
        {
            q = _queue = new PriorityQueue<DelaySource, long>();
            _fd = timerfd_create(ClockMonotonic, TfdNonblock | TfdCloexec);
            if (_fd < 0) throw new InvalidOperationException($"timerfd_create failed, errno {Marshal.GetLastPInvokeError()}");
            _buf = Marshal.AllocHGlobal(8);
            _completion = new Completion { Owner = reactor };
        }
        _completion!.Owner = reactor;

        long deadline = Stopwatch.GetTimestamp() + (long)(ms * (Stopwatch.Frequency / 1000.0));
        ValueTask wait = source.Wait();
        q.Enqueue(source, deadline);

        // Only re-arm when this wait is due before whatever the timer already holds.
        // Every wait that is not the new earliest costs nothing at all.
        if (!_readOutstanding || deadline < _armedFor)
        {
            Arm(reactor, deadline);
        }
        return wait;
    }

    private static unsafe void Arm(Reactor reactor, long deadline)
    {
        long remaining = deadline - Stopwatch.GetTimestamp();
        // A zero itimerspec disarms the timer rather than firing it, so a deadline
        // already in the past has to become the smallest possible positive interval.
        if (remaining < 1) remaining = 1;
        double perMs = Stopwatch.Frequency / 1000.0;
        long totalNs = (long)(remaining / perMs * 1_000_000.0);

        long* spec = stackalloc long[4];
        spec[0] = 0;
        spec[1] = 0;
        spec[2] = totalNs / 1_000_000_000L;
        spec[3] = totalNs % 1_000_000_000L;
        if (spec[2] == 0 && spec[3] == 0) spec[3] = 1;

        timerfd_settime(_fd, 0, spec, null);
        _armedFor = deadline;

        if (!_readOutstanding)
        {
            _readOutstanding = true;
            reactor.SubmitRead(_fd, _buf, 8, 0, _completion!);
        }
    }

    /// <summary>The timer fired: complete everything due and re-arm to the next one.</summary>
    private static void OnFired(Reactor reactor)
    {
        _readOutstanding = false;
        PriorityQueue<DelaySource, long>? q = _queue;
        if (q is null) return;

        long now = Stopwatch.GetTimestamp();
        while (q.TryPeek(out _, out long deadline) && deadline <= now)
        {
            q.Dequeue().Fire();
        }

        // Whatever the completions just queued is in here too, so the front of the
        // queue after draining is the next deadline this reactor has to cover.
        if (q.TryPeek(out _, out long next))
        {
            Arm(reactor, next);
        }
        else
        {
            _armedFor = 0;
        }
    }

    /// <summary>
    /// Carries the reactor so the completion can re-arm. One per reactor thread, made
    /// once and reused, so the timer costs no allocation either.
    /// </summary>
    private sealed class Completion : IRingCompletion
    {
        public Reactor? Owner;
        public void Complete(int result) => OnFired(Owner!);
    }

    /// <summary>Remembers which reactor this thread belongs to, for the re-arm.</summary>
    public static void Bind(Reactor reactor)
    {
        if (_completion is not null) _completion.Owner = reactor;
    }
}
