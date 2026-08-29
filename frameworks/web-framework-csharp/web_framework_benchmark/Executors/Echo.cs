namespace Executors;

using Framework;

public class Echo : StatefulExecutor
{
	// POST /echo returns the request body back verbatim.
	//
	// GetHttpBody() is the whole body regardless of framing, so a chunked
	// request works without a Content-Length to size it from.
	public override void DoPost(HttpRequest request, HttpResponse response)
	{
		response.SetBody(request.GetHttpBody());
	}
}
