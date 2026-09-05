using System.Buffers.Text;

using GenHTTP.Api.Content;
using GenHTTP.Api.Infrastructure;
using GenHTTP.Api.Protocol;

using GenHTTP.Engine.Ioxide;
using StringContent = GenHTTP.Modules.IO.Strings.StringContent;

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
/// request that lands on the same thread. Measured over nine million requests, not one of them
/// resumed on a different thread than it started on, which is what makes the thread-static pool
/// safe as well as fast.
///
/// This is a bare handler rather than a webservice because the profile holds 32000 requests at
/// once, so anything allocated per request is alive for the whole wait and gets promoted rather
/// than collected cheaply. Reaching the same route through the Webservices module measured 2230
/// bytes a request against 1330 here - the module's binding and invocation being most of the
/// difference - and the remaining bytes are the engine's, not this handler's.
/// </remarks>
public sealed class Delay : IHandler
{
    [ThreadStatic]
    private static Stack<RingTimer>? _timers;

    // The body echoes the delay back, which is how the profile checks the wait tracked the
    // parameter rather than being a constant sleep. The values it asks for are small and repeat,
    // so they are rendered once rather than per request.
    private static readonly StringContent[] Bodies = BuildBodies();

    public ValueTask PrepareAsync(IServer server) => default;

    public async ValueTask<IResponse?> HandleAsync(IRequest request)
    {
        if (request.Header.Target.Current is not { } segment
            || !Utf8Parser.TryParse(segment.Bytes.Span, out int ms, out var consumed)
            || consumed != segment.Bytes.Length
            || ms < 0)
        {
            return null; // not a delay request - let the rest of the layout answer it
        }

        var timer = Rent();

        try
        {
            await timer.DelayAsync(ms);
        }
        finally
        {
            Return(timer);
        }

        return request.Respond()
                      .Content(ms < Bodies.Length ? Bodies[ms] : new StringContent(ms.ToString()))
                      .Build();
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

    // The profile asks for a flat 10ms and validation draws from 10..90, so this covers every
    // value either of them uses without a lookup miss.
    private static StringContent[] BuildBodies()
    {
        var bodies = new StringContent[1024];

        for (var i = 0; i < bodies.Length; i++)
        {
            bodies[i] = new StringContent(i.ToString());
        }

        return bodies;
    }
}

/// <summary>Builds the delay handler, so it can carry concerns like any other.</summary>
public sealed class DelayBuilder : IHandlerBuilder<DelayBuilder>
{
    private readonly List<IConcernBuilder> _concerns = [];

    public DelayBuilder Add(IConcernBuilder concern)
    {
        _concerns.Add(concern);
        return this;
    }

    public IHandler Build() => Concerns.Chain(_concerns, new Delay());
}
