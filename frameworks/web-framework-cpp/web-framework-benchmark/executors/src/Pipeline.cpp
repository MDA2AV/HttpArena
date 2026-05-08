#include "Pipeline.hpp"

namespace executor
{
	void Pipeline::doGet(framework::HttpRequest& request, framework::HttpResponse& response)
	{
		constexpr std::string_view okResponse = "ok";

		response.addHeader("Content-Type", "text/plain");
		response.setBody(okResponse);
	}

	DEFINE_EXECUTOR(Pipeline);
}
