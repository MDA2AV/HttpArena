#pragma once

#include <Executors/HeavyOperationStatelessExecutor.hpp>

namespace executor
{
	class Static : public framework::HeavyOperationStatelessExecutor
	{
	public:
		void doGet(framework::HttpRequest& request, framework::HttpResponse& response) override;
	};
}
