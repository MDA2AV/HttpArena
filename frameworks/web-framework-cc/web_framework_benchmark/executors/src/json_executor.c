#include <executors/executor.h>

typedef struct json_executor
{
	json_object_t items;
	size_t size;
} json_executor_t;

DEFINE_EXECUTOR(json_executor_t, STATELESS_EXECUTOR)

DEFINE_EXECUTOR_INIT(json_executor_t)
{
	json_executor_t* self = (json_executor_t*)executor;
	char* data;
	size_t size;

	wf_get_file_executor_settings(settings, "dataset.json", &data, &size);

	json_parser_t parser;
	json_object_t parsed_data;

	wf_create_json_parser_from_string(data, &parser);
	wf_create_json_object(&self->items);

	wf_get_json_parser_parsed_data(parser, &parsed_data, true);
	wf_copy_json_object_array(&parsed_data, &self->items, &self->size);

	free(data);
	wf_delete_json_parser(parser);
}

DEFINE_EXECUTOR_METHOD(json_executor_t, GET_METHOD, request, response)
{
	json_executor_t* self = (json_executor_t*)executor;
	query_parameter_t* query_parameters;
	size_t size;
	int64_t count = 0;
	int64_t multiplier = 0;
	json_builder_t result;

	wf_create_json_builder(&result);

	wf_get_query_parameters(request, &query_parameters, &size);

	for (size_t i = 0; i < size; i++)
	{
		if (!strcmp(query_parameters[i].key, "m"))
		{
			multiplier = atoll(query_parameters[i].value);

			break;
		}
	}

	wf_get_route_integer_parameter(request, "count", &count);

	json_object_t* array = (json_object_t*)malloc(sizeof(json_object_t) * count);

	for (int i = 0; i < count; i++)
	{
		json_object_t temp;
		int64_t calculated;

		{
			json_object_t item;

			wf_index_access_json_object_array(&self->items, i, &item);

			wf_copy_json_object(&temp, &item);
		}

		{
			json_object_t current;

			wf_assign_or_get_json_object(&temp, "price", &current);
			wf_get_json_object_integer(&current, &calculated);
		}


		{
			json_object_t current;
			int64_t value;

			wf_assign_or_get_json_object(&temp, "quantity", &current);
			wf_get_json_object_integer(&current, &value);

			calculated *= value;
		}

		calculated *= multiplier;

		{
			json_object_t total;

			wf_assign_or_get_json_object(&temp, "total", &total);

			wf_set_json_object_integer(&total, calculated);
		}

		array[i] = temp;
	}

	wf_append_json_builder_integer(result, "count", count);
	wf_append_json_builder_array(result, "items", array, count);

	wf_set_json_body(response, result);

	free(query_parameters);

	for (int i = 0; i < count; i++)
	{
		wf_delete_json_object(&array[i]);
	}

	free(array);

	wf_delete_json_builder(result);
}
