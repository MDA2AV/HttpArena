using dogrider.Protocol;
using dogrider.Server;
using zerg.Engine.Configs;

namespace riderdog;

internal static class Program
{
    private static async Task Main()
    {
        await using var server = new Dogrider(
            new EngineOptions
            {
                Ip = "0.0.0.0",
                Port = 8080,
                Backlog = 16384,
                ReactorCount = 64,
                AcceptorConfig = new AcceptorConfig(
                    RingFlags: 0,
                    SqCpuThread: -1,
                    SqThreadIdleMs: 100,
                    RingEntries: 8 * 1024,
                    BatchSqes: 4096,
                    CqTimeout: 100_000_000,
                    IPVersion: IPVersion.IPv4Only
                ),
                ReactorConfigs = Enumerable.Range(0, 64).Select(_ => new ReactorConfig(
                    RingFlags: (1u << 12) | (1u << 13), // SINGLE_ISSUER | DEFER_TASKRUN
                    SqCpuThread: -1,
                    SqThreadIdleMs: 100,
                    RingEntries: 16 * 1024,
                    RecvBufferSize: 1 * 1024,
                    BufferRingEntries: 16 * 1024,
                    BatchCqes: 4096,
                    MaxConnectionsPerReactor: 1 * 512,
                    CqTimeout: 1_000_000,
                    ConnectionBufferRingEntries: 128,
                    IncrementalBufferConsumption: false
                )).ToArray()
            }, 
            handler: new EchoHandlerPipelined());

        server.Start();
        
        Console.WriteLine("dogrider listening on ws://0.0.0.0:8080/");

        var stop = new TaskCompletionSource();
        
        Console.CancelKeyPress += (_, e) =>
        {
            e.Cancel = true; stop.TrySetResult(); 
        };
        AppDomain.CurrentDomain.ProcessExit += (_, _) => stop.TrySetResult();
        
        await stop.Task;
        await server.StopAsync();
    }
}

internal sealed class EchoHandlerPipelined : Handler
{
    public async ValueTask HandleAsync(IConnection connection)
    {
        while (true)
        {
            var frames = await connection.ReadFramesAsync();

            foreach (var frame in frames)
            {
                if (frame.IsError(out var err))
                {
                    if (err.ErrorType is FrameErrorType.ConnectionClosed)
                    {
                        return;
                    }
                    
                    await connection.CloseAsync(reason: err.Message, statusCode: 1002);
                    
                    return;
                }

                switch (frame.Type)
                {
                    case FrameType.Text:
                        
                        connection.Write(frame.Payload.FirstSpan);
                        break;
                    
                    case FrameType.Binary:
                        
                        connection.Write(frame.Payload.FirstSpan);
                        break;
                    
                    case FrameType.Ping:
                        
                        connection.Pong(frame.Data);
                        break;
                    
                    case FrameType.Close:
                        
                        await connection.CloseAsync();
                        return;
                    
                    case FrameType.Pong:
                    case FrameType.Continue:
                        break;
                }
            }

            await connection.FlushAsync();
        }
    }
}
