using GenHTTP.Engine.Ioxide;
using GenHTTP.Modules.Webservices;

using ioxide.timer;

namespace genhttp.Tests;

/// <summary>
/// The async profile: hold the request for the requested number of milliseconds, then answer.
/// </summary>
/// <remarks>
/// The wait is a ring timeout, not <c>Task.Delay</c>. The deadline travels in the io_uring
/// submission, so the kernel holds it and the completion arrives back on the reactor thread with
/// the connection's state still warm - whereas Task.Delay resumes on the thread pool, which costs
/// a hop per request and takes the whole exchange off its reactor for the rest of its life.
///
/// One op is in flight per timer, so a timer cannot be shared by two waits that overlap. They are
/// pooled per reactor instead: rented for the wait, returned after it, and reused by the next
/// request that lands on the same thread.
/// </remarks>
public class Delay
{
    [ThreadStatic]
    private static Stack<RingTimer>? _timers;

    // The body echoes the delay back, which is how the profile checks that the wait tracked the
    // parameter rather than being a constant sleep.
    [ResourceMethod(":ms")]
    public async ValueTask<string> Wait(int ms)
    {
        var timer = Rent();

        try
        {
            await timer.DelayAsync(ms);
        }
        finally
        {
            Return(timer);
        }

        return ms.ToString();
    }

    // One off this reactor's pool, or a new one bound to the reactor serving this request.
    private static RingTimer Rent()
        => _timers is { } pool && pool.TryPop(out var timer) ? timer : new RingTimer(IoxideReactor.Current);

    private static void Return(RingTimer timer)
    {
        var pool = _timers ??= new Stack<RingTimer>();

        // A connection per timer at most; the ceiling keeps a burst from pinning memory for good.
        if (pool.Count < 4096)
        {
            pool.Push(timer);
        }
    }
}
