namespace Executors;

using Framework;

public class Upload : HeavyOperationStatefulExecutor
{
	private const int thresholdSize = 5242880;
	private int currentSize = 0;

	public override void DoPost(HttpRequest request, HttpResponse response)
	{
		if (int.Parse(request.GetHeaders()["Content-Length"]) >= thresholdSize)
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
