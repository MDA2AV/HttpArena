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

    // In imperative mode the handler answers the control frames itself (RFC 6455
    // 5.5): a Ping gets a Pong with its payload, and a Close gets a Close before
    // the connection ends. A frame the reader rejects fails the connection with
    // the code that says why, rather than dropping it; a read that ended because
    // the client went away leaves no one to tell.
    private static async ValueTask<bool> HandleAsync(IWebsocketFrame frame, IImperativeConnection connection)
    {
        switch (frame.Type)
        {
            case FrameType.Text or FrameType.Binary:
                await connection.WriteAsync(frame.Data, frame.Type, flush: false);
                return true;

            case FrameType.Ping:
                await connection.PongAsync(frame.Data, flush: false);
                return true;

            case FrameType.Close:
                await TryCloseAsync(connection, 1000);
                return false;

            case FrameType.Error:
                if (frame.IsError(out var error) && error.ErrorType is not (FrameErrorType.Canceled or FrameErrorType.IncompleteForever))
                {
                    await TryCloseAsync(connection, error.ErrorType == FrameErrorType.PayloadTooLarge ? (ushort)1009 : (ushort)1002);
                }
                return false;

            default:
                return true;
        }
    }

    // A disconnect is reported as a Close frame too, so the reply can find the
    // client gone; there is nothing left to do when it does.
    private static async ValueTask TryCloseAsync(IImperativeConnection connection, ushort statusCode)
    {
        try
        {
            await connection.CloseAsync(statusCode: statusCode);
        }
        catch (Exception)
        {
        }
    }
    
}