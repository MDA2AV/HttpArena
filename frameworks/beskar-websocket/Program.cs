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
            KeepAliveInterval = TimeSpan.Zero,
            OnMessageAsync = (session, payload, opcode) 
                => session.SendFrameAsync(payload, opcode)
        };

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
            _ = await listener.AcceptSessionAsync();
        }
    }
}
