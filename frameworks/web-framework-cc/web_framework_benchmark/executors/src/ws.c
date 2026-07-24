#include <executors/executor.h>
#include <web_socket/web_socket_executor.h>

DEFINE_DEFAULT_EXECUTOR(ws_t, STATELESS_EXECUTOR)

DEFINE_EXECUTOR_METHOD(ws_t, GET_METHOD, request, response)
{
	wf_set_http_response_code(response, BAD_REQUEST);
}

DEFINE_DEFAULT_WEB_SOCKET_EXECUTOR(web_socket_echo_t);

DEFINE_WEB_SOCKET_EXECUTOR_ON_RECEIVE(web_socket_echo_t)
{
	web_socket_frame_t frame = WF_GET_WEB_SOCKET_FRAME();
	web_socket_frame_type_t type;
	char* payload;
	uint64_t size;

	wf_web_socket_frame_get_type(frame, &type);
	wf_web_socket_frame_get_payload(frame, &payload, &size);

	switch (type)
	{
	case FRAME_TYPE_TEXT:
	case FRAME_TYPE_BINARY:
		WF_SEND_WEB_SOCKET_FRAME(payload, size, type);

		break;

	case FRAME_TYPE_CLOSE:
	{
		uint16_t code = 1000;
		const char message[] = "validate done";
		const char data[sizeof(code) + sizeof(message)];

		memcpy(data, &code, sizeof(code));
		memcpy(data + sizeof(code), message, sizeof(message));

		WF_SEND_WEB_SOCKET_FRAME(data, sizeof(data), type);
	}

	break;
	}
}
