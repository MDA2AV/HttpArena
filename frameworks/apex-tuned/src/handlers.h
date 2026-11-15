#pragma once

#include "server.h"

extern __thread worker_t *t_worker;

void baseline_handler(context_t *context);
void pipeline_handler(context_t *context);
void delay_handler(context_t *context);
void json_handler(context_t *context);
void echo_handler(context_t *context);

void handle_timer_expiration(worker_t *worker, conn_t *connection, int64_t delay_milliseconds);
void register_application_routes(worker_t *worker);
