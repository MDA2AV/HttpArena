#include "h2.h"
#include "connection.h"
#include "dataset.h"
#include "response_builder.h"
#include "static_files.h"

#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

void flush_data(worker_t *worker, conn_t *connection, const char *data, size_t length);
void close_conn(worker_t *worker, conn_t *connection);

#define H2_WRITE_COALESCE_SIZE (64 * 1024)

_Static_assert(H2_WRITE_COALESCE_SIZE <= WRITE_BUF_SIZE, "H2 coalescing buffer exceeds worker write buffer");

static ssize_t h2_send_callback(nghttp2_session *session, const uint8_t *data, size_t length, int flags,
                                void *user_data) {
    (void)session;
    (void)flags;

    h2_connection_t *h2_conn = (h2_connection_t *)user_data;
    worker_t *worker = h2_conn->worker;

    if (length > H2_WRITE_COALESCE_SIZE) {
        return NGHTTP2_ERR_CALLBACK_FAILURE;
    }
    if (length > H2_WRITE_COALESCE_SIZE - worker->h2_write_pos) {
        return NGHTTP2_ERR_WOULDBLOCK;
    }

    memcpy(worker->write_buf + worker->h2_write_pos, data, length);
    worker->h2_write_pos += length;
    return (ssize_t)length;
}

bool h2_connection_drain_send(conn_t *connection, worker_t *worker) {
    h2_connection_t *h2_conn = (h2_connection_t *)connection->h2;
    if (!h2_conn || !h2_conn->session) {
        return false;
    }
    if (connection->pending_write) {
        return true;
    }

    h2_conn->worker = worker;
    while (nghttp2_session_want_write(h2_conn->session)) {
        worker->h2_write_pos = 0;
        int send_status = nghttp2_session_send(h2_conn->session);
        size_t buffered_bytes = worker->h2_write_pos;
        if (send_status != 0) {
            worker->h2_write_pos = 0;
            return false;
        }
        if (buffered_bytes == 0) {
            break;
        }

        flush_data(worker, connection, worker->write_buf, buffered_bytes);
        worker->h2_write_pos = 0;
        if (connection->fd < 0) {
            return false;
        }
        if (connection->pending_write) {
            break;
        }
    }

    return true;
}

static ssize_t h2_data_read_callback(nghttp2_session *session, int32_t stream_id, uint8_t *destination_buffer,
                                     size_t max_length, uint32_t *data_flags, nghttp2_data_source *source,
                                     void *user_data) {
    (void)session;
    (void)user_data;

    h2_connection_t *h2_conn = (h2_connection_t *)source->ptr;
    int stream_slot_index = (stream_id >> 1) & H2_STREAM_SLOT_MASK;
    h2_stream_slot_t *slot = &h2_conn->stream_slots[stream_slot_index];

    const char *payload_data = NULL;
    size_t payload_length = 0;
    size_t *sent_ptr = NULL;

    if (slot->dynamic_response_buffer != NULL) {
        payload_data = slot->dynamic_response_buffer;
        payload_length = slot->dynamic_response_length;
        sent_ptr = &slot->dynamic_response_sent;
    } else {
        payload_data = slot->inline_response_buffer;
        payload_length = slot->inline_response_length;
    }

    size_t sent = sent_ptr ? *sent_ptr : 0;
    if (sent >= payload_length) {
        *data_flags |= NGHTTP2_DATA_FLAG_EOF;
        return 0;
    }

    size_t remaining = payload_length - sent;
    size_t to_send = remaining > max_length ? max_length : remaining;

    if (to_send > 0 && payload_data != NULL) {
        memcpy(destination_buffer, payload_data + sent, to_send);
        if (sent_ptr) {
            *sent_ptr += to_send;
        }
        if (h2_conn->connection && h2_conn->connection->in_stalled_list) {
            h2_conn->connection->stalled_since_ms = clock_monotonic_ms();
        }
    }

    if (sent + to_send >= payload_length) {
        *data_flags |= NGHTTP2_DATA_FLAG_EOF;
    }

    return (ssize_t)to_send;
}

static inline bool header_contains_token(const uint8_t *header_value, size_t value_length,
                                          const char *token, size_t token_length) {
    if (value_length < token_length) {
        return false;
    }
    for (size_t offset = 0; offset <= value_length - token_length; offset++) {
        if (memcmp(header_value + offset, token, token_length) == 0) {
            return true;
        }
    }
    return false;
}

static int h2_on_header_callback(nghttp2_session *session, const nghttp2_frame *frame, const uint8_t *header_name,
                                 size_t name_length, const uint8_t *header_value, size_t value_length, uint8_t flags,
                                 void *user_data) {
    (void)session;
    (void)flags;

    h2_connection_t *h2_conn = (h2_connection_t *)user_data;

    if (frame->hd.type == NGHTTP2_HEADERS) {
        int stream_slot_index = (frame->hd.stream_id >> 1) & H2_STREAM_SLOT_MASK;
        h2_stream_slot_t *slot = &h2_conn->stream_slots[stream_slot_index];

        if (name_length == 5 && memcmp(header_name, ":path", 5) == 0) {
            size_t copy_length = value_length < (H2_MAX_PATH_LENGTH - 1) ? value_length : (H2_MAX_PATH_LENGTH - 1);
            memcpy(slot->request_path, header_value, copy_length);
            slot->request_path[copy_length] = '\0';
            slot->request_path_length = copy_length;
        } else if (name_length == 7 && memcmp(header_name, ":method", 7) == 0) {
            if (value_length == 4 && memcmp(header_value, "HEAD", 4) == 0) {
                slot->is_head = true;
            }
        } else if (name_length == 15 && memcmp(header_name, "accept-encoding", 15) == 0) {
            if (header_contains_token(header_value, value_length, "br", 2)) {
                slot->accept_br = true;
            }
            if (header_contains_token(header_value, value_length, "gzip", 4)) {
                slot->accept_gzip = true;
            }
        }
    }

    return 0;
}

static int h2_on_stream_close_callback(nghttp2_session *session, int32_t stream_id, uint32_t error_code,
                                       void *user_data) {
    (void)session;
    (void)error_code;

    h2_connection_t *h2_conn = (h2_connection_t *)user_data;
    int stream_slot_index = (stream_id >> 1) & H2_STREAM_SLOT_MASK;
    h2_stream_slot_t *slot = &h2_conn->stream_slots[stream_slot_index];

    if (slot->dynamic_response_buffer != NULL) {
        bool counted_dynamic_stream = !slot->is_dynamic_buffer_static_memory;
        if (slot->is_pooled_buffer) {
            buffer_pool_release(&h2_conn->worker->buffer_pool, slot->dynamic_response_buffer);
        } else if (!slot->is_dynamic_buffer_static_memory) {
            free(slot->dynamic_response_buffer);
        }
        slot->dynamic_response_buffer = NULL;
        slot->dynamic_response_length = 0;
        slot->dynamic_response_sent = 0;
        slot->is_dynamic_buffer_static_memory = false;
        slot->is_pooled_buffer = false;
        if (counted_dynamic_stream && h2_conn->active_dynamic_streams > 0) {
            h2_conn->active_dynamic_streams--;
            if (h2_conn->active_dynamic_streams == 0) {
                conn_unmark_stalled(h2_conn->worker, h2_conn->connection);
            }
        }
    }

    slot->inline_response_length = 0;
    slot->request_path_length = 0;
    slot->is_head = false;
    slot->accept_br = false;
    slot->accept_gzip = false;
    return 0;
}

static int handle_h2_baseline_request(nghttp2_session *session, h2_connection_t *h2_conn, int32_t stream_id,
                                       const char *request_path) {
    int stream_slot_index = (stream_id >> 1) & H2_STREAM_SLOT_MASK;
    h2_stream_slot_t *slot = &h2_conn->stream_slots[stream_slot_index];

    int64_t calculated_sum = 0;
    const char *query_delimiter = memchr(request_path, '?', slot->request_path_length);
    if (query_delimiter != NULL) {
        const char *query = query_delimiter + 1;
        size_t query_length = slot->request_path_length - (size_t)(query - request_path);
        calculated_sum = calculate_query_integer_sum_fast(query, query_length);
    }

    slot->inline_response_length = format_i64(slot->inline_response_buffer, calculated_sum);

    nghttp2_nv response_headers[] = {
        {(uint8_t *)":status", (uint8_t *)"200", 7, 3, NGHTTP2_NV_FLAG_NONE},
        {(uint8_t *)"content-type", (uint8_t *)"text/plain", 12, 10, NGHTTP2_NV_FLAG_NONE}};

    nghttp2_data_provider data_provider = {.source.ptr = h2_conn, .read_callback = h2_data_read_callback};

    return nghttp2_submit_response(session, stream_id, response_headers, 2,
                                   slot->is_head ? NULL : &data_provider);
}

static int handle_h2_json_request(nghttp2_session *session, h2_connection_t *h2_conn, int32_t stream_id,
                                   const char *request_path) {
    int stream_slot_index = (stream_id >> 1) & H2_STREAM_SLOT_MASK;
    h2_stream_slot_t *slot = &h2_conn->stream_slots[stream_slot_index];

    int64_t item_count = 50;
    const char *count_string = request_path + 6;
    char *parse_end = NULL;
    item_count = strtoll(count_string, &parse_end, 10);
    if (item_count < 1)
        item_count = 1;
    if (item_count > 50)
        item_count = 50;

    int64_t multiplier = 1;
    const char *multiplier_parameter = strstr(request_path, "m=");
    if (multiplier_parameter != NULL) {
        multiplier = strtoll(multiplier_parameter + 2, NULL, 10);
    }

    int remote_window = nghttp2_session_get_stream_remote_window_size(session, stream_id);
    int session_window = nghttp2_session_get_remote_window_size(session);
    if (__builtin_expect(remote_window < 1024 || session_window < 1024, 0)) {
        nghttp2_submit_rst_stream(session, NGHTTP2_FLAG_NONE, stream_id, NGHTTP2_FLOW_CONTROL_ERROR);
        return 0;
    }

    const char *cached_payload = NULL;
    size_t cached_payload_length =
        json_cached_payload((size_t)item_count, multiplier, &cached_payload);
    if (cached_payload_length > 0) {
        slot->dynamic_response_buffer = (char *)(uintptr_t)cached_payload;
        slot->dynamic_response_length = cached_payload_length;
        slot->dynamic_response_sent = 0;
        slot->is_dynamic_buffer_static_memory = true;
        slot->is_pooled_buffer = false;
    } else {
        if (__builtin_expect(h2_conn->active_dynamic_streams >= 32, 0)) {
            nghttp2_submit_rst_stream(session, NGHTTP2_FLAG_NONE, stream_id, NGHTTP2_REFUSED_STREAM);
            return 0;
        }

        char *json_serialized_buffer = buffer_pool_acquire(&h2_conn->worker->buffer_pool);
        bool is_pooled = true;
        if (!json_serialized_buffer) {
            json_serialized_buffer = malloc(16384);
            is_pooled = false;
        }
        if (!json_serialized_buffer) {
            nghttp2_submit_rst_stream(session, NGHTTP2_FLAG_NONE, stream_id, NGHTTP2_INTERNAL_ERROR);
            return 0;
        }

        if (h2_conn->active_dynamic_streams == 0) {
            conn_mark_stalled(h2_conn->worker, h2_conn->connection);
        }
        h2_conn->active_dynamic_streams++;
        size_t json_serialized_length =
            json_serialize((size_t)item_count, multiplier, json_serialized_buffer, 16384);

        slot->dynamic_response_buffer = json_serialized_buffer;
        slot->dynamic_response_length = json_serialized_length;
        slot->dynamic_response_sent = 0;
        slot->is_dynamic_buffer_static_memory = false;
        slot->is_pooled_buffer = is_pooled;
    }

    nghttp2_nv response_headers[] = {
        {(uint8_t *)":status", (uint8_t *)"200", 7, 3, NGHTTP2_NV_FLAG_NONE},
        {(uint8_t *)"content-type", (uint8_t *)"application/json", 12, 16, NGHTTP2_NV_FLAG_NONE}};

    nghttp2_data_provider data_provider = {.source.ptr = h2_conn, .read_callback = h2_data_read_callback};

    return nghttp2_submit_response(session, stream_id, response_headers, 2,
                                   slot->is_head ? NULL : &data_provider);
}

static int handle_h2_pipeline_request(nghttp2_session *session, h2_connection_t *h2_conn, int32_t stream_id) {
    int stream_slot_index = (stream_id >> 1) & H2_STREAM_SLOT_MASK;
    h2_stream_slot_t *slot = &h2_conn->stream_slots[stream_slot_index];

    memcpy(slot->inline_response_buffer, "ok", 2);
    slot->inline_response_length = 2;
    slot->dynamic_response_sent = 0;

    nghttp2_nv response_headers[] = {
        {(uint8_t *)":status", (uint8_t *)"200", 7, 3, NGHTTP2_NV_FLAG_NONE},
        {(uint8_t *)"content-type", (uint8_t *)"text/plain", 12, 10, NGHTTP2_NV_FLAG_NONE}};

    nghttp2_data_provider data_provider = {.source.ptr = h2_conn, .read_callback = h2_data_read_callback};

    return nghttp2_submit_response(session, stream_id, response_headers, 2,
                                   slot->is_head ? NULL : &data_provider);
}

static int handle_h2_static_request(nghttp2_session *session, h2_connection_t *h2_conn, int32_t stream_id,
                                     const char *request_path) {
    int remote_window = nghttp2_session_get_stream_remote_window_size(session, stream_id);
    int session_window = nghttp2_session_get_remote_window_size(session);
    if (__builtin_expect(remote_window < 1024 || session_window < 1024, 0)) {
        nghttp2_submit_rst_stream(session, NGHTTP2_FLAG_NONE, stream_id, NGHTTP2_FLOW_CONTROL_ERROR);
        return 0;
    }

    int stream_slot_index = (stream_id >> 1) & H2_STREAM_SLOT_MASK;
    h2_stream_slot_t *slot = &h2_conn->stream_slots[stream_slot_index];

    const char *relative_file_path = request_path + 8;
    static_file_result_t file_result;
    if (!static_cache_lookup(relative_file_path, slot->accept_br, slot->accept_gzip, &file_result)) {
        return -1;
    }

    slot->dynamic_response_buffer = (char *)(uintptr_t)file_result.data;
    slot->dynamic_response_length = file_result.size;
    slot->dynamic_response_sent = 0;
    slot->is_dynamic_buffer_static_memory = true;

    char content_length_str[32];
    size_t content_length_length = format_i64(content_length_str, (int64_t)file_result.size);

    nghttp2_nv response_headers[5];
    size_t header_count = 0;

    response_headers[header_count++] = (nghttp2_nv){
        (uint8_t *)":status", (uint8_t *)"200", 7, 3, NGHTTP2_NV_FLAG_NONE};
    response_headers[header_count++] = (nghttp2_nv){
        (uint8_t *)"content-type", (uint8_t *)(uintptr_t)file_result.mime_type, 12,
        strlen(file_result.mime_type), NGHTTP2_NV_FLAG_NONE};
    response_headers[header_count++] = (nghttp2_nv){
        (uint8_t *)"content-length", (uint8_t *)content_length_str, 14,
        content_length_length, NGHTTP2_NV_FLAG_NONE};

    if (file_result.content_encoding != NULL) {
        size_t content_encoding_length = file_result.content_encoding[0] == 'b' ? 2 : 4;
        response_headers[header_count++] = (nghttp2_nv){
            (uint8_t *)"content-encoding", (uint8_t *)(uintptr_t)file_result.content_encoding, 16,
            content_encoding_length, NGHTTP2_NV_FLAG_NONE};
        response_headers[header_count++] = (nghttp2_nv){
            (uint8_t *)"vary", (uint8_t *)"accept-encoding", 4, 15, NGHTTP2_NV_FLAG_NONE};
    }

    nghttp2_data_provider data_provider = {.source.ptr = h2_conn, .read_callback = h2_data_read_callback};

    return nghttp2_submit_response(session, stream_id, response_headers, (int)header_count,
                                   slot->is_head ? NULL : &data_provider);
}

static int handle_h2_not_found(nghttp2_session *session, h2_connection_t *h2_conn, int32_t stream_id) {
    int stream_slot_index = (stream_id >> 1) & H2_STREAM_SLOT_MASK;
    h2_stream_slot_t *slot = &h2_conn->stream_slots[stream_slot_index];

    memcpy(slot->inline_response_buffer, "Not Found", 9);
    slot->inline_response_length = 9;

    nghttp2_nv response_headers[] = {
        {(uint8_t *)":status", (uint8_t *)"404", 7, 3, NGHTTP2_NV_FLAG_NONE},
        {(uint8_t *)"content-type", (uint8_t *)"text/plain", 12, 10, NGHTTP2_NV_FLAG_NONE}};

    nghttp2_data_provider data_provider = {.source.ptr = h2_conn, .read_callback = h2_data_read_callback};

    return nghttp2_submit_response(session, stream_id, response_headers, 2,
                                   slot->is_head ? NULL : &data_provider);
}

static int h2_on_frame_recv_callback(nghttp2_session *session, const nghttp2_frame *frame, void *user_data) {
    h2_connection_t *h2_conn = (h2_connection_t *)user_data;

    if (frame->hd.type == NGHTTP2_HEADERS && (frame->hd.flags & NGHTTP2_FLAG_END_STREAM)) {
        int stream_slot_index = (frame->hd.stream_id >> 1) & H2_STREAM_SLOT_MASK;
        const char *request_path = h2_conn->stream_slots[stream_slot_index].request_path;

        if (strncmp(request_path, "/baseline2", 10) == 0 || strncmp(request_path, "/baseline11", 11) == 0) {
            return handle_h2_baseline_request(session, h2_conn, frame->hd.stream_id, request_path);
        }

        if (strncmp(request_path, "/json/", 6) == 0) {
            return handle_h2_json_request(session, h2_conn, frame->hd.stream_id, request_path);
        }

        if (strncmp(request_path, "/pipeline", 9) == 0) {
            return handle_h2_pipeline_request(session, h2_conn, frame->hd.stream_id);
        }

        if (strncmp(request_path, "/static/", 8) == 0) {
            if (handle_h2_static_request(session, h2_conn, frame->hd.stream_id, request_path) == 0) {
                return 0;
            }
        }

        return handle_h2_not_found(session, h2_conn, frame->hd.stream_id);
    }

    return 0;
}

bool h2_connection_init(conn_t *connection, worker_t *worker) {
    h2_connection_t *h2_conn = calloc(1, sizeof(h2_connection_t));
    if (!h2_conn) {
        return false;
    }

    h2_conn->connection = connection;
    h2_conn->worker = worker;
    connection->h2 = h2_conn;

    nghttp2_session_callbacks *callbacks;
    if (nghttp2_session_callbacks_new(&callbacks) != 0) {
        free(h2_conn);
        connection->h2 = NULL;
        return false;
    }

    nghttp2_session_callbacks_set_send_callback(callbacks, h2_send_callback);
    nghttp2_session_callbacks_set_on_header_callback(callbacks, h2_on_header_callback);
    nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, h2_on_frame_recv_callback);
    nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, h2_on_stream_close_callback);

    int status = nghttp2_session_server_new(&h2_conn->session, callbacks, h2_conn);
    nghttp2_session_callbacks_del(callbacks);
    if (status != 0) {
        free(h2_conn);
        connection->h2 = NULL;
        return false;
    }

    nghttp2_settings_entry server_settings[] = {{NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, 100},
                                                {NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, 65535}};
    nghttp2_submit_settings(h2_conn->session, NGHTTP2_FLAG_NONE, server_settings, 2);

    if (!h2_connection_drain_send(connection, worker)) {
        return false;
    }

    return true;
}

bool h2_connection_process_incoming_data(conn_t *connection, worker_t *worker, const char *input_buffer,
                                         size_t input_length) {
    h2_connection_t *h2_conn = (h2_connection_t *)connection->h2;
    if (!h2_conn || !h2_conn->session) {
        return false;
    }

    h2_conn->worker = worker;
    ssize_t processed_bytes = nghttp2_session_mem_recv(h2_conn->session, (const uint8_t *)input_buffer, input_length);
    if (processed_bytes < 0) {
        return false;
    }

    return true;
}

void h2_connection_destroy(conn_t *connection) {
    if (!connection->h2) {
        return;
    }

    h2_connection_t *h2_conn = (h2_connection_t *)connection->h2;
    if (h2_conn->session != NULL) {
        nghttp2_session_del(h2_conn->session);
        h2_conn->session = NULL;
    }

    for (int slot_index = 0; slot_index < H2_MAX_CONCURRENT_STREAMS; slot_index++) {
        h2_stream_slot_t *slot = &h2_conn->stream_slots[slot_index];
        if (slot->dynamic_response_buffer != NULL) {
            if (slot->is_pooled_buffer) {
                buffer_pool_release(&h2_conn->worker->buffer_pool, slot->dynamic_response_buffer);
            } else if (!slot->is_dynamic_buffer_static_memory) {
                free(slot->dynamic_response_buffer);
            }
            slot->dynamic_response_buffer = NULL;
            slot->is_pooled_buffer = false;
        }
    }

    free(h2_conn);
    connection->h2 = NULL;
}
