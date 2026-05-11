namespace Executors;

using Framework;

public class Upload : StatefulExecutor
{
	private int currentSize = 0;

	public override void DoPost(HttpRequest request, HttpResponse response)
	{
		const int thresholdSize = 5242880;

		IDictionary<string, string> headers = request.GetHeaders();
		string temp = headers["Content-Length"];
		int contentLength = int.Parse(temp);

		if (contentLength >= thresholdSize)
		{
			var (data, last) = request.GetLargeData();

			currentSize += data.Length;

			if (last)
			{
				response.SetBody($"{currentSize}");
			}
		}
		else
		{
			currentSize = request.GetHttpBody().Length;

			response.SetBody($"{currentSize}");
		}
	}
}
