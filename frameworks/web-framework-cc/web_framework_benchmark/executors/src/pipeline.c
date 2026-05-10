#include <executors/executor.h>

DEFINE_DEFAULT_EXECUTOR(pipeline_t, STATELESS_EXECUTOR)

DEFINE_EXECUTOR_METHOD(pipeline_t, GET_METHOD, request, response)
{
	const char ok[] = "ok";

	wf_set_body(response, ok, strlen(ok));
}
