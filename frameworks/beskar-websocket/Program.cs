using System.IO.Pipelines;
using System.Net;
using Beskar.Networking.Transports.Ws;

namespace beskar_websocket;

internal static class Program
{
    private static async Task Main()
    {
        var options = new WsTransportOptions
        {
            Path = "/ws",
            KeepAliveInterval = TimeSpan.Zero
        };
        options.TcpOptions.SocketOptions.IoQueueCount = Environment.ProcessorCount;

        var endPoint = new IPEndPoint(IPAddress.Any, 8080);
        var listener = new WsNetworkListener(endPoint, options);

        var bindResult = await listener.BindAsync();
        if (bindResult.Failed)
        {
            Console.WriteLine($"Failed to bind WebSocket listener: {bindResult.Error.Message}");
            return;
        }

        Console.WriteLine("Application started.");

        while (true)
        {
            var sessionResult = await listener.AcceptSessionAsync();
            if (sessionResult.Failed)
            {
                break;
            }

            var session = sessionResult.Success;
            _ = Task.Run(async () =>
            {
                try
                {
                    var streamResult = await session.AcceptStreamAsync();
                    if (streamResult.Failed)
                    {
                        await session.DisposeAsync();
                        return;
                    }

                    var stream = streamResult.Success;
                    var reader = stream.Transport.Input;
                    var writer = stream.Transport.Output;

                    while (true)
                    {
                        if (!reader.TryRead(out var result))
                        {
                            result = await reader.ReadAsync();
                        }
                        var buffer = result.Buffer;

                        if (!buffer.IsEmpty)
                        {
                            foreach (var segment in buffer)
                            {
                                var span = writer.GetSpan(segment.Length);
                                segment.Span.CopyTo(span);
                                writer.Advance(segment.Length);
                            }
                            await writer.FlushAsync();
                            reader.AdvanceTo(buffer.End);
                        }
                        else
                        {
                            reader.AdvanceTo(buffer.Start, buffer.End);
                        }

                        if (result.IsCompleted || result.IsCanceled)
                        {
                            break;
                        }
                    }
                }
                catch
                {
                    // Catch connection resets or unexpected client drops cleanly
                }
                finally
                {
                    await session.DisposeAsync();
                }
            });
        }
    }
}
