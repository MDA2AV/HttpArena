namespace Executors;

using Framework;

public class Pipeline : StatelessExecutor
{
	public override void DoGet(HttpRequest request, HttpResponse response)
	{
		response.AddHeader("Content-Type", "text/plain");
		response.SetBody("ok");
	}
}
