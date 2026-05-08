#pragma once

#include <Executors/HeavyOperationStatelessExecutor.hpp>

namespace executor
{
	class Upload : public framework::HeavyOperationStatelessExecutor
	{
	private:
		size_t currentSize;

	public:
		Upload();

		void doPost(framework::HttpRequest& request, framework::HttpResponse& response) override;

		~Upload() = default;
	};
}
