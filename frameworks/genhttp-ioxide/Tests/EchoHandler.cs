using GenHTTP.Modules.Websockets;
using GenHTTP.Modules.Websockets.Protocol;

namespace genhttp.Tests;


public sealed class EchoHandler : IImperativeHandler
{
    
    public async ValueTask HandleAsync(IImperativeConnection connection)
    {
        while (connection.Request.Server.Running)
        {
            var frame = await connection.ReadFrameAsync();

            if (!await HandleAsync(frame, connection)) return;

            while (connection.TryReadFrame(out frame))
            {
                if (!await HandleAsync(frame, connection)) return;
            }

            await connection.FlushAsync();
        }
    }

    private static async ValueTask<bool> HandleAsync(IWebsocketFrame frame, IImperativeConnection connection)
    {
        if (frame.Type == FrameType.Close)
        {
            return false;
        }

        if (frame.Type is FrameType.Text or FrameType.Binary)
        {
            await connection.WriteAsync(frame.Data, frame.Type, flush: false);
        }

        return true;
    }
    
}