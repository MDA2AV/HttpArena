namespace Executors;

using Framework;
using Framework.Utility;

public class Ws : StatelessExecutor
{
	public override void DoGet(HttpRequest request, HttpResponse response)
	{
		response.SetResponseCode(ResponseCodes.BadRequest);
	}
}

public class WebSocketEcho : WebSocketExecutor
{
	public override FramePayload? OnReceive(Frame frame, ref Frame.Close? close)
	{
		switch (frame.GetFrameType())
		{
			case Frame.Type.text:
			case Frame.Type.binary:
				return frame.GetPayload();
				
			case Frame.Type.close:
				close = new(Frame.Close.Code.normalClosure, "validate done");

				return null;

			default:
				return null;
		}
	}
}
