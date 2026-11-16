#include "handlers.h"
#include "connection.h"
#include "dataset.h"
#include "response_builder.h"
#include "static_files.h"
#include "worker.h"

#include <errno.h>
#include <string.h>
#include <sys/socket.h>

__thread worker_t *t_worker = NULL;

void baseline_handler(context_t *context) {
    request_t *request = context->req;
    response_t *response = context->res;
    conn_t *connection = (conn_t *)context->user_data;

    int64_t accumulated_sum = 0;
    if (__builtin_expect(request->num_params == 2, 1)) {
        str_view_t first_value = request->params[0].val;
        str_view_t second_value = request->params[1].val;
        uint64_t parsed_sum;
        bool parsed_fast;

        if (__builtin_expect(first_value.len == second_value.len, 1)) {
            parsed_fast = sum_two_ascii_digits_fast(first_value.ptr, second_value.ptr, first_value.len, &parsed_sum);
        } else {
            uint64_t first_param_value = 0;
            uint64_t second_param_value = 0;
            bool first_parsed = parse_ascii_digits_fast(first_value.ptr, first_value.len, &first_param_value);
            bool second_parsed = parse_ascii_digits_fast(second_value.ptr, second_value.len, &second_param_value);
            parsed_fast = first_parsed && second_parsed;
            parsed_sum = first_param_value + second_param_value;
        }

        if (__builtin_expect(parsed_fast, 1)) {
            accumulated_sum = (int64_t)parsed_sum;
        } else {
            int64_t first_param_value = 0;
            int64_t second_param_value = 0;
            parse_i64(first_value.ptr, first_value.len, &first_param_value);
            parse_i64(second_value.ptr, second_value.len, &second_param_value);
            accumulated_sum = first_param_value + second_param_value;
        }
    } else {
        for (size_t param_index = 0; param_index < request->num_params; param_index++) {
            int64_t parameter_value = 0;
            if (parse_i64(request->params[param_index].val.ptr, request->params[param_index].val.len,
                          &parameter_value)) {
                accumulated_sum += parameter_value;
            }
        }
    }

    if (request->method == HTTP_METHOD_POST && request->body.len > 0) {
        int64_t body_value = 0;
        if (parse_i64(request->body.ptr, request->body.len, &body_value)) {
            accumulated_sum += body_value;
        }
    }

    size_t formatted_length = (size_t)format_i64(connection->scratch, accumulated_sum);
    res_set_text(response, connection->scratch, formatted_length);
}

void pipeline_handler(context_t *context) {
    res_set_text(context->res, "ok", 2);
}

void delay_handler(context_t *context) {
    request_t *request = context->req;
    response_t *response = context->res;
    conn_t *connection = (conn_t *)context->user_data;

    int64_t delay_milliseconds = 0;
    if (request->num_route_params > 0) {
        str_view_t route_parameter = request->route_params[0];
        if (route_parameter.len == 2 && route_parameter.ptr[0] == '1' && route_parameter.ptr[1] == '0') {
            delay_milliseconds = 10;
        } else {
            parse_i64(route_parameter.ptr, route_parameter.len, &delay_milliseconds);
        }
    }

    if (delay_milliseconds <= 0) {
        size_t formatted_length = (size_t)format_i64(connection->scratch, 0);
        res_set_text(response, connection->scratch, formatted_length);
        return;
    }

    connection->timer_val_ms = delay_milliseconds;
    connection->keep_alive = request->keep_alive;
    context->async_parked = true;
}

static void parse_json_request_parameters(const request_t *request, size_t *out_item_count,
                                          int64_t *out_multiplier) {
    int64_t item_count = 50;
    if (request->path.len >= 6 && memcmp(request->path.ptr, "/json/", 6) == 0) {
        const char *count_start = request->path.ptr + 6;
        size_t count_length = request->path.len - 6;
        unsigned int first_digit = count_length > 0
                                       ? (unsigned int)(unsigned char)count_start[0] - (unsigned int)'0'
                                       : 10;
        if (__builtin_expect(count_length == 1 && first_digit <= 9, 1)) {
            item_count = (int64_t)first_digit;
        } else if (__builtin_expect(count_length == 2, 1)) {
            unsigned int second_digit = (unsigned int)(unsigned char)count_start[1] - (unsigned int)'0';
            if (first_digit <= 9 && second_digit <= 9) {
                item_count = (int64_t)(first_digit * 10 + second_digit);
            } else if (first_digit <= 9 && count_start[1] == '/') {
                item_count = (int64_t)first_digit;
            } else {
                parse_i64(count_start, count_length, &item_count);
            }
        } else {
            const char *slash = memchr(count_start, '/', count_length);
            if (slash) {
                count_length = (size_t)(slash - count_start);
            }
            parse_i64(count_start, count_length, &item_count);
        }
    }
    if (item_count < 1) {
        item_count = 1;
    } else if (item_count > 50) {
        item_count = 50;
    }

    int64_t multiplier = 1;
    if (request->query.ptr && request->query.len > 0) {
        const char *query = request->query.ptr;
        unsigned int digit = request->query.len == 3
                                 ? (unsigned int)(unsigned char)query[2] - (unsigned int)'0'
                                 : 10;
        if (__builtin_expect(request->query.len == 3 && query[0] == 'm' && query[1] == '=' && digit <= 9, 1)) {
            multiplier = (int64_t)digit;
        } else {
            const char *cursor = query;
            const char *query_end = cursor + request->query.len;
            for (size_t parameter_index = 0; cursor < query_end && parameter_index < MAX_PARAMS; parameter_index++) {
                const char *field_end = memchr(cursor, '&', (size_t)(query_end - cursor));
                if (!field_end) {
                    field_end = query_end;
                }
                const char *equals_separator = memchr(cursor, '=', (size_t)(field_end - cursor));
                if (equals_separator && equals_separator == cursor + 1 && cursor[0] == 'm') {
                    parse_i64(equals_separator + 1, (size_t)(field_end - equals_separator - 1), &multiplier);
                    break;
                }
                cursor = field_end < query_end ? field_end + 1 : query_end;
            }
        }
    }

    *out_item_count = (size_t)item_count;
    *out_multiplier = multiplier;
}

static bool json_accepts_gzip(const request_t *request) {
    str_view_t accept_encoding = request->accept_encoding;
    if (!accept_encoding.ptr || accept_encoding.len < 4) {
        return false;
    }
    for (size_t index = 0; index + 4 <= accept_encoding.len; index++) {
        const unsigned char *candidate = (const unsigned char *)accept_encoding.ptr + index;
        if ((candidate[0] | 0x20) == 'g' && (candidate[1] | 0x20) == 'z' && (candidate[2] | 0x20) == 'i' &&
            (candidate[3] | 0x20) == 'p') {
            return true;
        }
    }
    return false;
}

void json_handler(context_t *context) {
    request_t *request = context->req;
    response_t *response = context->res;
    worker_t *worker = t_worker;

    size_t item_count;
    int64_t multiplier = 1;
    parse_json_request_parameters(request, &item_count, &multiplier);

    bool accepts_gzip = json_accepts_gzip(request);
    if (!accepts_gzip) {
        const char *cached_payload = NULL;
        size_t cached_payload_length = json_cached_payload(item_count, multiplier, &cached_payload);
        if (cached_payload_length > 0) {
            res_set_json(response, cached_payload, cached_payload_length);
            response->content_encoding = NULL;
            return;
        }
    }

    size_t json_length = json_serialize(item_count, multiplier, worker->compress.json_buf,
                                        sizeof(worker->compress.json_buf));
    if (accepts_gzip) {
        size_t compressed_length = 0;
        if (compress_gzip(&worker->compress, worker->compress.json_buf, json_length, worker->compress.comp_buf,
                          sizeof(worker->compress.comp_buf), &compressed_length) == 0) {
            res_set_json(response, worker->compress.comp_buf, compressed_length);
            response->content_encoding = "gzip";
            return;
        }
    }

    res_set_json(response, worker->compress.json_buf, json_length);
    response->content_encoding = NULL;
}

size_t format_json_http1_response(const request_t *request, worker_t *worker, char *destination_buffer,
                                  size_t max_destination_size, const char **out_response_start) {
    enum { JSON_HEADER_RESERVE = 128 };
    static const char header_prefix[] =
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ";
    static const char keep_alive_suffix[] = "\r\nConnection: keep-alive\r\n\r\n";
    static const char keep_alive_gzip_suffix[] =
        "\r\nContent-Encoding: gzip\r\nConnection: keep-alive\r\n\r\n";
    static const char close_suffix[] = "\r\nConnection: close\r\n\r\n";
    static const char close_gzip_suffix[] = "\r\nContent-Encoding: gzip\r\nConnection: close\r\n\r\n";

    if (max_destination_size <= JSON_HEADER_RESERVE || !out_response_start) {
        return 0;
    }

    size_t item_count;
    int64_t multiplier;
    parse_json_request_parameters(request, &item_count, &multiplier);

    bool accepts_gzip = json_accepts_gzip(request);
    if (!accepts_gzip && request->keep_alive) {
        size_t response_length =
            json_cached_http1_response(item_count, multiplier, out_response_start);
        if (response_length > 0) {
            return response_length;
        }
    }
    if (accepts_gzip && request->keep_alive) {
        size_t response_length = json_gzip_http1_response(&worker->compress, item_count, multiplier,
                                                          destination_buffer, max_destination_size,
                                                          out_response_start);
        if (response_length > 0) {
            return response_length;
        }
    }

    char *body_start = destination_buffer + JSON_HEADER_RESERVE;
    size_t body_capacity = max_destination_size - JSON_HEADER_RESERVE;
    size_t body_length;
    bool use_gzip = accepts_gzip;
    if (use_gzip) {
        size_t json_length = json_serialize(item_count, multiplier, worker->compress.json_buf,
                                            sizeof(worker->compress.json_buf));
        if (compress_gzip(&worker->compress, worker->compress.json_buf, json_length, body_start, body_capacity,
                          &body_length) != 0) {
            if (json_length > body_capacity) {
                return 0;
            }
            memcpy(body_start, worker->compress.json_buf, json_length);
            body_length = json_length;
            use_gzip = false;
        }
    } else {
        body_length = json_serialize(item_count, multiplier, body_start, body_capacity);
    }

    if (body_length > body_capacity || body_length > UINT32_MAX) {
        return 0;
    }

    char content_length_buffer[10];
    size_t content_length_length = format_u32(content_length_buffer, (uint32_t)body_length);
    const char *header_suffix;
    size_t header_suffix_length;
    if (request->keep_alive) {
        if (use_gzip) {
            header_suffix = keep_alive_gzip_suffix;
            header_suffix_length = sizeof(keep_alive_gzip_suffix) - 1;
        } else {
            header_suffix = keep_alive_suffix;
            header_suffix_length = sizeof(keep_alive_suffix) - 1;
        }
    } else if (use_gzip) {
        header_suffix = close_gzip_suffix;
        header_suffix_length = sizeof(close_gzip_suffix) - 1;
    } else {
        header_suffix = close_suffix;
        header_suffix_length = sizeof(close_suffix) - 1;
    }

    size_t header_length =
        sizeof(header_prefix) - 1 + content_length_length + header_suffix_length;
    if (header_length > JSON_HEADER_RESERVE) {
        return 0;
    }

    char *header_start = body_start - header_length;
    char *cursor = header_start;
    memcpy(cursor, header_prefix, sizeof(header_prefix) - 1);
    cursor += sizeof(header_prefix) - 1;
    memcpy(cursor, content_length_buffer, content_length_length);
    cursor += content_length_length;
    memcpy(cursor, header_suffix, header_suffix_length);

    *out_response_start = header_start;
    return header_length + body_length;
}

void echo_handler(context_t *context) {
    request_t *request = context->req;
    response_t *response = context->res;
    res_set_binary(response, request->body.ptr, request->body.len, "application/octet-stream");
}

void handle_timer_expiration(worker_t *worker, conn_t *connection, int64_t delay_milliseconds,
                             uint64_t current_time_ms) {
    connection->parked_in_timer = false;
    conn_touch(worker, connection, current_time_ms);

    static const char response_delay_10[] = "HTTP/1.1 200 OK\r\n"
                                            "Content-Type: text/plain\r\n"
                                            "Content-Length: 2\r\n"
                                            "Connection: keep-alive\r\n\r\n10";
    static const size_t response_delay_10_length = sizeof(response_delay_10) - 1;

    if (__builtin_expect(delay_milliseconds == 10 && connection->keep_alive, 1)) {
        if (__builtin_expect(!connection->is_tls, 1)) {
            ssize_t bytes_sent =
                send(connection->fd, response_delay_10, response_delay_10_length, MSG_NOSIGNAL | MSG_DONTWAIT);
            if (__builtin_expect(bytes_sent == (ssize_t)response_delay_10_length, 1)) {
            } else if (bytes_sent > 0) {
                flush_data(worker, connection, response_delay_10 + bytes_sent,
                           response_delay_10_length - (size_t)bytes_sent);
            } else if (bytes_sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                flush_data(worker, connection, response_delay_10, response_delay_10_length);
            } else {
                close_conn(worker, connection);
                return;
            }
        } else {
            flush_data(worker, connection, response_delay_10, response_delay_10_length);
        }
    } else {
        response_t response;
        res_init(&response, connection->keep_alive);
        char number_buffer[24];
        size_t formatted_length = (size_t)format_i64(number_buffer, delay_milliseconds);
        res_set_text(&response, number_buffer, formatted_length);

        size_t bytes_written = res_serialize(&response, worker->write_buf, sizeof(worker->write_buf));
        if (bytes_written > 0) {
            flush_data(worker, connection, worker->write_buf, bytes_written);
        }
    }

    if (connection->fd >= 0 && connection->read_pos > 0 && !connection->closing && !connection->parked_in_timer) {
        process_requests(worker, connection);
    }
}

void register_application_routes(worker_t *worker) {
    router_init(&worker->router);
    router_add(&worker->router, HTTP_METHOD_GET, "/", pipeline_handler);
    router_add(&worker->router, HTTP_METHOD_HEAD, "/", pipeline_handler);
    router_add(&worker->router, HTTP_METHOD_GET, "/pipeline", pipeline_handler);
    router_add(&worker->router, HTTP_METHOD_GET, "/query", baseline_handler);
    router_add(&worker->router, HTTP_METHOD_GET, "/baseline11", baseline_handler);
    router_add(&worker->router, HTTP_METHOD_POST, "/baseline11", baseline_handler);
    router_add(&worker->router, HTTP_METHOD_GET, "/baseline2", baseline_handler);
    router_add(&worker->router, HTTP_METHOD_GET, "/delay/:ms", delay_handler);
    router_add(&worker->router, HTTP_METHOD_GET, "/json", json_handler);
    router_add(&worker->router, HTTP_METHOD_GET, "/json/:count", json_handler);
    router_add(&worker->router, HTTP_METHOD_POST, "/echo", echo_handler);
    router_add(&worker->router, HTTP_METHOD_GET, "/static/", static_file_handler);
    router_add(&worker->router, HTTP_METHOD_HEAD, "/static/", static_file_handler);
}
