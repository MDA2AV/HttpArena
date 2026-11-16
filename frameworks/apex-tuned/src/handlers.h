#pragma once

#include "server.h"

extern __thread worker_t *t_worker;

void baseline_handler(context_t *context);
void pipeline_handler(context_t *context);
void delay_handler(context_t *context);
void json_handler(context_t *context);
size_t format_json_http1_response(const request_t *request, worker_t *worker, char *destination_buffer,
                                  size_t max_destination_size, const char **out_response_start);
void echo_handler(context_t *context);

void handle_timer_expiration(worker_t *worker, conn_t *connection, int64_t delay_milliseconds,
                             uint64_t current_time_ms);
void register_application_routes(worker_t *worker);
