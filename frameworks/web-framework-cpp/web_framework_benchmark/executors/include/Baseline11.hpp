#pragma once

#include <Executors/StatelessExecutor.hpp>

namespace executor
{
	class Baseline11 : public framework::StatelessExecutor
	{
	private:
		static void parseValues(framework::HttpRequest& request, int& a, int& b);

	public:
		void doGet(framework::HttpRequest& request, framework::HttpResponse& response) override;

		void doPost(framework::HttpRequest& request, framework::HttpResponse& response) override;
	};
}
