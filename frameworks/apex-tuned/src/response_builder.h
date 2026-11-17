#pragma once

#include "server.h"

int64_t calculate_query_integer_sum_fast(const char *query, size_t query_length);
int64_t parse_integer_fast(const char *buffer, size_t buffer_length);
bool parse_baseline_request_fast(const char *buffer, size_t buffer_length, size_t *out_consumed_bytes,
                                 int64_t *out_sum);

size_t format_plain_text_pipeline_response(char *destination_buffer, bool keep_alive, bool *out_closing);
size_t format_plain_text_baseline_response(char *destination_buffer, int64_t accumulated_sum, bool keep_alive,
                                           bool *out_closing);

bool flush_pending_write(worker_t *worker, conn_t *connection);
void flush_data(worker_t *worker, conn_t *connection, const char *data, size_t length);
