using System.Threading.Tasks.Sources;

using ioxide;

namespace IoxideArena;

/// <summary>
/// A wait that runs on the reactor's own ring: the deadline goes to the kernel with the
/// submission, so it completes on the thread that owns this connection with its state still
/// warm, and the reactor is free for everything else it owns meanwhile.
///
/// This is ioxide.timer's RingTimer, kept here because that package missed the 0.7.211
/// release even though the SubmitTimeout it needs did ship. It goes away for a package
/// reference the moment ioxide.timer is published (MDA2AV/ioxide#213).
///
/// One op in flight per instance, which is what a connection needs: it only ever waits once
/// at a time, because the handler awaits before it reads again. Nothing is allocated per wait.
///
/// Expiry arrives the way io_uring reports it, as -ETIME, which is success for a timeout
/// rather than a failure - so the result is not what says the wait is over.
/// </summary>
internal sealed class RingTimer : IRingCompletion, IValueTaskSource
{
    private const long NanosecondsPerMillisecond = 1_000_000L;

    // Continuations run inline on the completing thread, which is the reactor thread.
    private ManualResetValueTaskSourceCore<bool> _core = new() { RunContinuationsAsynchronously = false };

    private readonly Reactor _reactor;

    public RingTimer(Reactor reactor)
    {
        _reactor = reactor;
    }

    /// <summary>Completes once <paramref name="milliseconds"/> have elapsed.</summary>
    public ValueTask DelayAsync(int milliseconds)
    {
        short token = _core.Version;
        _reactor.SubmitTimeout(milliseconds * NanosecondsPerMillisecond, this);
        return new ValueTask(this, token);
    }

    public void Complete(int result) => _core.SetResult(true);

    public void GetResult(short token)
    {
        _core.GetResult(token);
        // Re-arm for this connection's next wait. After the result is taken, or the token the
        // awaiter is holding stops matching.
        _core.Reset();
    }

    public ValueTaskSourceStatus GetStatus(short token) => _core.GetStatus(token);

    public void OnCompleted(Action<object?> continuation, object? state, short token, ValueTaskSourceOnCompletedFlags flags)
        => _core.OnCompleted(continuation, state, token, flags);
}
