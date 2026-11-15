#pragma once

#include "server.h"
#include <nghttp2/nghttp2.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define H2_MAX_CONCURRENT_STREAMS 128
#define H2_STREAM_SLOT_MASK (H2_MAX_CONCURRENT_STREAMS - 1)
#define H2_MAX_PATH_LENGTH 128
#define H2_INLINE_RESPONSE_BUFFER_SIZE 32

typedef struct h2_stream_slot_s {
    char *dynamic_response_buffer;
    size_t dynamic_response_length;
    size_t request_path_length;
    size_t inline_response_length;
    char request_path[H2_MAX_PATH_LENGTH];
    char inline_response_buffer[H2_INLINE_RESPONSE_BUFFER_SIZE];
    bool is_dynamic_buffer_static_memory;
    bool is_pooled_buffer;
    bool is_head;
    bool accept_br;
    bool accept_gzip;
} h2_stream_slot_t;

typedef struct h2_connection_s {
    conn_t *connection;
    worker_t *worker;
    nghttp2_session *session;
    uint16_t active_dynamic_streams;
    h2_stream_slot_t stream_slots[H2_MAX_CONCURRENT_STREAMS];
} h2_connection_t;

bool h2_connection_init(conn_t *connection, worker_t *worker);

bool h2_connection_process_incoming_data(conn_t *connection, worker_t *worker, const char *input_buffer,
                                         size_t input_length);

void h2_connection_destroy(conn_t *connection);
