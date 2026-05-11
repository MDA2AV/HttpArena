namespace Executors;

using Framework;

public class Upload : StatefulExecutor
{
	private int currentSize;
	private bool? isLargeData;

	public override void DoPost(HttpRequest request, HttpResponse response)
	{
		if (isLargeData == null)
		{
			const int thresholdSize = 102400;

			currentSize = 0;

			IDictionary<string, string> headers = request.GetHeaders();
			string temp = headers["Content-Length"];
			int contentLength = int.Parse(temp);

			isLargeData = contentLength >= thresholdSize;
		}

		if ((bool)isLargeData)
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
