#include <executors/executor.h>

#define THRESHOLD_SIZE 102400

typedef struct upload
{
	int current_size;
} upload_t;

DEFINE_EXECUTOR(upload_t, STATEFUL_EXECUTOR)

DEFINE_EXECUTOR_INIT(upload_t)
{
	((upload_t*)executor)->current_size = 0;
}

DEFINE_EXECUTOR_METHOD(upload_t, POST_METHOD, request, response)
{
	upload_t* self = (upload_t*)executor;
	const char* contentLength;

	wf_get_http_header(request, "Content-Length", &contentLength);

	if (atoi(contentLength) >= THRESHOLD_SIZE)
	{
		const large_data_t* data = NULL;
		
		wf_get_large_data(request, &data);

		self->current_size += data->data_part_size;

		if (data->is_last_packet)
		{
			char buffer[32];

			memset(buffer, 0, sizeof(buffer));

			snprintf(buffer, sizeof(buffer), "%d", self->current_size);

			wf_set_body(response, buffer, sizeof(buffer));
		}
	}
	else
	{
		const char* body;
		size_t size;

		wf_get_http_body(request, &body, &size);

		self->current_size += size;

		char buffer[32];

		memset(buffer, 0, sizeof(buffer));

		snprintf(buffer, sizeof(buffer), "%d", self->current_size);

		wf_set_body(response, buffer, sizeof(buffer));
	}
}
