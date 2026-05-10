#pragma once

#include <Executors/StatelessExecutor.hpp>

namespace executor
{
	class JsonExecutor : public framework::StatelessExecutor
	{
	private:
		framework::JsonObject dataset;
		std::vector<framework::JsonObject> items;

	public:
		void init(const framework::utility::ExecutorSettings& settings) override;

		void doGet(framework::HttpRequest& request, framework::HttpResponse& response) override;
	};
}
