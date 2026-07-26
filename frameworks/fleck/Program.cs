using Fleck;

namespace fleckws;

internal static class Program
{
    private static async Task Main()
    {
        var server = new WebSocketServer("ws://0.0.0.0:8080/");
        Console.WriteLine("ooga fleck");
        server.Start(socket =>
        {
            socket.OnMessage = message => socket.Send(message);
            socket.OnBinary = binary => socket.Send(binary);
        });

        await Task.Delay(-1);
    }
}
