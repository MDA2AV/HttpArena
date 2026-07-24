#pragma once

#include <Executors/StatefulExecutor.hpp>

namespace executor
{
	class Upload : public framework::StatefulExecutor
	{
	private:
		size_t currentSize;

	public:
		Upload();

		void doPost(framework::HttpRequest& request, framework::HttpResponse& response) override;

		~Upload() = default;
	};
}
