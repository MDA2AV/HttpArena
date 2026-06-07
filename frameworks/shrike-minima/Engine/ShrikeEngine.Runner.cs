// ReSharper disable always CheckNamespace
// ReSharper disable always SuggestVarOrType_BuiltInTypes
#pragma warning disable CA2014

namespace Shrike;

public sealed partial class ShrikeEngine
{
    /// <summary>
    /// Boots the engine. Each worker owns its own epoll instance and its own
    /// SO_REUSEPORT listen socket — the kernel load-balances accepts across them,
    /// so there is no acceptor thread (this mirrors Minima's per-reactor model).
    /// Worker 0 runs on the calling thread (blocks for the process lifetime); the
    /// rest run on background threads.
    /// </summary>
    public void Run()
    {
        var workers = new Worker[_nWorkers];
        for (int i = 0; i < _nWorkers; i++)
            workers[i] = new Worker(i, _maxEventsPerWake, _port, _backlog);

        Console.WriteLine($"Shrike listening on 0.0.0.0:{_port} with {_nWorkers} worker(s) (SO_REUSEPORT, no acceptor)");

        for (int i = 1; i < _nWorkers; i++)
        {
            int iCap = i;
            var t = new Thread(() => WorkerLoop(workers[iCap]), _maxStackSizePerThread)
            {
                IsBackground = true,
                Name = $"worker-{iCap}"
            };
            t.Start();
        }

        WorkerLoop(workers[0]);   // run one worker on the calling thread; blocks
    }
}
