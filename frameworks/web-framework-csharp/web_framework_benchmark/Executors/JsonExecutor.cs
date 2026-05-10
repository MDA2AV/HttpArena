namespace Executors;

using Framework;
using System.Text.Json.Nodes;

public class JsonExecutor : StatelessExecutor
{
	private JsonArray? _items;

	public override void Init(ExecutorSettings settings) => _items = JsonNode.Parse(settings.GetFile("dataset.json"))!.AsArray();

	public override void DoGet(HttpRequest request, HttpResponse response)
	{
		int multiplier = int.Parse(request.GetQueryParameters()["m"]);
		int count = request.GetRouteParameter<int>("count");
		var result = new
		{
			count,
			items = new JsonArray()
		};

		for (int i = 0; i < count; i++)
		{
			JsonObject temp = _items!.ElementAt(i)!.AsObject().DeepClone().AsObject();

			temp["total"] = temp["price"]!.GetValue<int>() * temp["quantity"]!.GetValue<int>() * multiplier;

			result.items.Add(temp);
		}

		response.SetBody(result);
	}
}
