#pragma once

#include <Executors/HeavyOperationStatefulExecutor.hpp>

namespace executor
{
	class Upload : public framework::HeavyOperationStatefulExecutor
	{
	private:
		size_t currentSize;

	public:
		Upload();

		void doPost(framework::HttpRequest& request, framework::HttpResponse& response) override;

		~Upload() = default;
	};
}
