#include "JsonExecutor.hpp"

#include <charconv>

namespace executor
{
	void JsonExecutor::init(const framework::utility::ExecutorSettings& settings)
	{
		dataset = framework::JsonParser(settings.getFile("dataset.json")).getParsedData(true);
		items = dataset.get<std::vector<framework::JsonObject>>();
	}

	void JsonExecutor::doGet(framework::HttpRequest& request, framework::HttpResponse& response)
	{
		const std::string& queryParameter = request.getQueryParameters().at("m");
		int count = request.getRouteParameter<int>("count");
		int multiplier;
		framework::JsonBuilder result;
		std::vector<framework::JsonObject> resultItems;

		resultItems.reserve(count);

		std::from_chars(queryParameter.data(), queryParameter.data() + queryParameter.size(), multiplier);

		for (int i = 0; i < count; i++)
		{
			framework::JsonObject temp(items[i]);

			temp["total"] = temp["price"].get<int>() * temp["quantity"].get<int>() * multiplier;

			resultItems.emplace_back(std::move(temp));
		}

		result["count"] = count;
		result["items"] = std::move(resultItems);

		response.setBody(result);
	}

	DEFINE_EXECUTOR(JsonExecutor);
}
