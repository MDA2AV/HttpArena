using System.Net;

using GenHTTP.Engine.Internal;
using GenHTTP.Modules.Layouting;
using GenHTTP.Modules.Websockets;
using GenHTTP.Modules.Websockets.Protocol;

var websocket = Websocket.Imperative()
                         .DoNotAllocateFrameData()
                         .Handler(new EchoHandler());

var app = Layout.Create()
                .Add("ws", websocket);

var host = Host.Create().Handler(app);

host.Bind(IPAddress.Any, 8080);

Console.WriteLine("Application started.");
await host.RunAsync();

class EchoHandler : IImperativeHandler
{
    public async ValueTask HandleAsync(IImperativeConnection connection)
    {
        while (true)
        {
            var frame = await connection.ReadFrameAsync();

            if (frame.Type == FrameType.Close)
                break;

            if (frame.Type == FrameType.Text || frame.Type == FrameType.Binary)
            {
                await connection.WriteAsync(frame.Data, frame.Type);
            }
        }
    }
}
