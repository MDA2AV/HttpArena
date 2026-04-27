using GenHTTP.Modules.Websockets;
using GenHTTP.Modules.Websockets.Protocol;

namespace genhttp.Tests;

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
