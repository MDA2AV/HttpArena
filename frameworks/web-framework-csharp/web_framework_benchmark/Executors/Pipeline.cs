namespace Executors;

using Framework;

public class Pipeline : StatelessExecutor
{
	public override void DoGet(HttpRequest request, HttpResponse response)
	{
		response.SetBody("ok");
	}
}
