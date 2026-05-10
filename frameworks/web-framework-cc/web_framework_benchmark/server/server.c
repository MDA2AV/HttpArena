#include <stdlib.h>
#include <stdint.h>

#include <import.h>

static void on_start();

int main(int argc, char** argv)
{
	wf_initialize_web_framework("WebFramework");

	config_t config;
	const char* ptr = getenv("THREADS");

	web_framework_exception_t exception = wf_create_config_from_path("config.json", &config);

	if (exception)
	{
		fprintf(stderr, "%s\n", wf_get_error_message(exception));

		wf_delete_web_framework_exception(exception);

		return 1;
	}

	if (ptr)
	{
		int64_t value = atoll(ptr);

		if (value > 8)
		{
			exception = wf_override_configuration_integer(config, "threadCount", value - 8, true);
		}
	}

	if (exception)
	{
		fprintf(stderr, "%s\n", wf_get_error_message(exception));

		wf_delete_config(config);
		wf_delete_web_framework_exception(exception);

		return 2;
	}

	ptr = getenv("H2THREADS");

	if (ptr)
	{
		// TODO: HTTP/2.0
	}

	web_framework_t server;

	exception = wf_create_web_framework_from_config(config, &server);

	if (exception)
	{
		fprintf(stderr, "%s\n", wf_get_error_message(exception));

		wf_delete_config(config);
		wf_delete_web_framework_exception(exception);

		return 3;
	}

	exception = wf_start_web_framework_server(server, true, on_start);

	if (exception)
	{
		fprintf(stderr, "%s\n", wf_get_error_message(exception));

		wf_delete_config(config);
		wf_delete_web_framework(server);
		wf_delete_web_framework_exception(exception);

		return 4;
	}

	return 0;
}

void on_start()
{
	printf("Server is running...\n");
}
