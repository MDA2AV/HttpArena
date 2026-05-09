#include "Pipeline.hpp"

namespace executor
{
	void Pipeline::doGet(framework::HttpRequest& request, framework::HttpResponse& response)
	{
		response.setBody("ok");
	}

	DEFINE_EXECUTOR(Pipeline);
}
