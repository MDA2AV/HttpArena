namespace Executors;

using Framework;
using System.Text;

public class Baseline11 : StatelessExecutor
{
	private static void ParseValues(HttpRequest request, out int a, out int b)
	{
		IDictionary<string, string> queryParameters = request.GetQueryParameters();

		a = int.Parse(queryParameters["a"]);
		b = int.Parse(queryParameters["b"]);
	}

	public override void DoGet(HttpRequest request, HttpResponse response)
	{
		ParseValues(request, out int a, out int b);

		response.SetBody($"{a + b}");
	}

	public override void DoPost(HttpRequest request, HttpResponse response)
	{
		IDictionary<string, string> headers = request.GetHeaders();
		int c;

		ParseValues(request, out int a, out int b);

		if (headers.ContainsKey("Transfer-Encoding"))
		{
			c = int.Parse(Encoding.ASCII.GetString(request.GetChunks()[0]));
		}
		else
		{
			c = int.Parse(request.GetHttpBody());
		}

		response.SetBody($"{a + b + c}");
	}
}
