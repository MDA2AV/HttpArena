#pragma once

#include <string>

#include <Executors/StatefulExecutor.hpp>

namespace executor
{
	class Echo : public framework::StatefulExecutor
	{
	private:
		std::string buffer;

	public:
		Echo() = default;

		void doPost(framework::HttpRequest& request, framework::HttpResponse& response) override;

		~Echo() = default;
	};
}
