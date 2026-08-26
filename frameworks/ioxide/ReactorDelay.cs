using System.Diagnostics;

using ioxide;

namespace IoxideArena;

/// <summary>
/// A wait that keeps the request on the reactor that owns it.
///
/// The async profile answers <c>GET /delay/{ms}</c> after the milliseconds named
/// in the path, with 64,000 connections in flight, so every one of them is a
/// pending timer. <c>Task.Delay</c> is the wrong tool twice over: its
/// continuation resumes on the thread pool, which drags a connection off the
/// reactor that owns its ring and buffers, and it allocates a timer per call.
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
    // 250us. The profile's shortest wait is 15ms, so the tick contributes under
    // 2% of it, and a coarser tick would show up as a systematic overshoot in a
    // number that is being compared between frameworks.
    private const int TickMicroseconds = 250;

    private static readonly List<Reactor> Reactors = [];
    private static readonly Lock ReactorsGate = new();
    private static readonly Action<object?> DrainCallback = _ => Drain();
    private static int _started;

    // Touched only by the reactor thread that owns it: the handler parks a
    // request from this thread, and the drain runs on this thread too.
    [ThreadStatic] private static PriorityQueue<TaskCompletionSource, long>? _pending;

    /// <summary>Completes after <paramref name="ms"/>, on this reactor's thread.</summary>
    public static Task Delay(Reactor reactor, int ms)
    {
        if (ms <= 0) return Task.CompletedTask;

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
            q = _pending = new PriorityQueue<TaskCompletionSource, long>();
            Register(reactor);
        }

        // Continuations run synchronously on whichever thread completes the
        // source, and that is deliberately the reactor thread - the whole point
        // is that the connection never leaves it.
        var tcs = new TaskCompletionSource();
        q.Enqueue(tcs, Stopwatch.GetTimestamp() + (long)(ms * (Stopwatch.Frequency / 1000.0)));
        return tcs.Task;
    }

    private static void Register(Reactor reactor)
    {
        lock (ReactorsGate)
        {
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
        var spin = new SpinWait();
        long tickTicks = Stopwatch.Frequency / 1_000_000L * TickMicroseconds;
        long next = Stopwatch.GetTimestamp();
        while (true)
        {
            next += tickTicks;
            // Sleep(0)/SpinOnce rather than Sleep(1): the scheduler's millisecond
            // granularity is coarser than the tick this has to keep.
            while (Stopwatch.GetTimestamp() < next)
            {
                spin.SpinOnce(-1);
            }
            spin.Reset();

            lock (ReactorsGate)
            {
                for (int i = 0; i < Reactors.Count; i++)
                {
                    try
                    {
                        Reactors[i].ScheduleOnReactor(DrainCallback, null);
                    }
                    catch
                    {
                        // A reactor shutting down is not this thread's problem.
                    }
                }
            }
        }
    }

    /// <summary>Runs on a reactor thread: complete everything now due.</summary>
    private static void Drain()
    {
        PriorityQueue<TaskCompletionSource, long>? q = _pending;
        if (q is null || q.Count == 0) return;

        long now = Stopwatch.GetTimestamp();
        while (q.TryPeek(out _, out long deadline) && deadline <= now)
        {
            q.Dequeue().TrySetResult();
        }
    }
}
