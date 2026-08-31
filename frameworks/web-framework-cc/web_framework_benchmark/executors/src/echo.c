#include <executors/executor.h>

// The server hands a body of at least this size to the executor a packet at a
// time instead of in one piece; it mirrors largeBodySizeThreshold in
// config.json, and the benchmark's 100 KB body sits exactly on it.
#define THRESHOLD_SIZE 102400

typedef struct echo
{
	char* buffer;
	size_t size;
	size_t capacity;
} echo_t;

DEFINE_EXECUTOR(echo_t, STATEFUL_EXECUTOR)

DEFINE_EXECUTOR_INIT(echo_t)
{
	echo_t* self = (echo_t*)executor;

	self->buffer = NULL;
	self->size = 0;
	self->capacity = 0;
}

DEFINE_EXECUTOR_DESTROY(echo_t)
{
	free(((echo_t*)executor)->buffer);
}

// Grows the per-client scratch buffer, which is reused across requests rather
// than reallocated for each one.
static bool reserve(echo_t* self, size_t capacity)
{
	if (self->capacity >= capacity)
	{
		return true;
	}

	char* buffer = (char*)realloc(self->buffer, capacity);

	if (!buffer)
	{
		return false;
	}

	self->buffer = buffer;
	self->capacity = capacity;

	return true;
}

// A body-less response is serialized as 204 with no Content-Length at all, so
// the status and the framing of an empty echo have to be spelled out here.
static void send_echo(http_response_t response, const char* body, size_t size)
{
	wf_set_http_response_code(response, OK);
	wf_add_http_response_header(response, "Content-Type", "application/octet-stream");

	if (size)
	{
		wf_set_body(response, body, size);
	}
	else
	{
		wf_add_http_response_header(response, "Content-Length", "0");
	}
}

DEFINE_EXECUTOR_METHOD(echo_t, POST_METHOD, request, response)
{
	echo_t* self = (echo_t*)executor;
	http_header_t* headers = NULL;
	size_t headers_size = 0;
	bool chunked = false;
	long long content_length = 0;

	wf_get_http_headers(request, &headers, &headers_size);

	for (size_t i = 0; i < headers_size; i++)
	{
		if (!strcmp(headers[i].key, "Transfer-Encoding"))
		{
			chunked = true;
		}
		else if (!strcmp(headers[i].key, "Content-Length"))
		{
			content_length = atoll(headers[i].value);
		}
	}

	free(headers);

	if (chunked)
	{
		// A chunked request carries no Content-Length, so the body only exists
		// as the decoded chunks: they are concatenated here, and the response
		// is framed from what they add up to.
		http_chunk_t* chunks = NULL;
		size_t chunks_size = 0;
		size_t total = 0;
		size_t offset = 0;

		wf_get_chunks(request, &chunks, &chunks_size);

		for (size_t i = 0; i < chunks_size; i++)
		{
			total += chunks[i].size;
		}

		if (!reserve(self, total))
		{
			free(chunks);

			return;
		}

		for (size_t i = 0; i < chunks_size; i++)
		{
			memcpy(self->buffer + offset, chunks[i].data, chunks[i].size);

			offset += chunks[i].size;
		}

		free(chunks);

		send_echo(response, self->buffer, total);
	}
	else if (content_length >= THRESHOLD_SIZE)
	{
		// One packet per call, each pointing at a receive buffer that is reused
		// for the next one, so every packet has to be copied out as it lands.
		// The response can only be written once the last one has arrived.
		const large_data_t* data = NULL;

		wf_get_large_data(request, &data);

		if (!reserve(self, self->size + data->data_part_size))
		{
			self->size = 0;

			return;
		}

		memcpy(self->buffer + self->size, data->data_part, data->data_part_size);

		self->size += data->data_part_size;

		if (data->is_last_packet)
		{
			send_echo(response, self->buffer, self->size);

			self->size = 0;
		}
	}
	else
	{
		const char* body;
		size_t size;

		wf_get_http_body(request, &body, &size);

		send_echo(response, body, size);
	}
}
