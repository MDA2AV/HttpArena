#include <executors/executor.h>

static void parse_values(http_request_t request, int* a, int* b);

DEFINE_DEFAULT_EXECUTOR(baseline11_t, STATELESS_EXECUTOR)

DEFINE_EXECUTOR_METHOD(baseline11_t, GET_METHOD, request, response)
{
	int a;
	int b;

	parse_values(request, &a, &b);

	char buffer[32];

	memset(buffer, 0, sizeof(buffer));
	snprintf(buffer, sizeof(buffer), "%d", a + b);

	wf_set_body(response, buffer, sizeof(buffer));
}

DEFINE_EXECUTOR_METHOD(baseline11_t, POST_METHOD, request, response)
{
	int a;
	int b;
	int c;
	bool chunked = false;
	http_header_t* headers = NULL;
	size_t size;

	parse_values(request, &a, &b);

	wf_get_http_headers(request, &headers, &size);

	for (size_t i = 0; i < size; i++)
	{
		if (!strcmp(headers[i].key, "Transfer-Encoding"))
		{
			chunked = true;

			break;
		}
	}

	if (chunked)
	{
		http_chunk_t* chunks;
		size_t size;

		wf_get_chunks(request, &chunks, &size);

		c = atoi(chunks[0].data);

		free(chunks);
	}
	else
	{
		const char* body;
		size_t size;

		wf_get_http_body(request, &body, &size);

		c = atoi(body);
	}

	char buffer[32];

	memset(buffer, 0, sizeof(buffer));
	snprintf(buffer, sizeof(buffer), "%d", a + b + c);

	free(headers);

	wf_set_body(response, buffer, sizeof(buffer));
}

void parse_values(http_request_t request, int* a, int* b)
{
	query_parameter_t* query_parameters = NULL;
	size_t size;

	wf_get_query_parameters(request, &query_parameters, &size);

	for (size_t i = 0; i < size; i++)
	{
		if (!strcmp(query_parameters[i].key, "a"))
		{
			*a = atoi(query_parameters[i].value);
		}
		else if (!strcmp(query_parameters[i].key, "b"))
		{
			*b = atoi(query_parameters[i].value);
		}
	}
}

DEFINE_INITIALIZE_WEB_FRAMEWORK()
