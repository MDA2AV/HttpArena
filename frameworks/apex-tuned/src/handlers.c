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
    for (size_t param_index = 0; param_index < request->num_params; param_index++) {
        int64_t parameter_value = 0;
        if (parse_i64(request->params[param_index].val.ptr, request->params[param_index].val.len, &parameter_value)) {
            accumulated_sum += parameter_value;
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

    connection->parked_in_timer = true;
    connection->timer_expire_us = clock_monotonic_us() + (uint64_t)delay_milliseconds * 1000ULL;
    connection->timer_val_ms = delay_milliseconds;
    connection->keep_alive = request->keep_alive;
    context->async_parked = true;
}

void json_handler(context_t *context) {
    request_t *request = context->req;
    response_t *response = context->res;
    worker_t *worker = t_worker;

    int64_t item_count = 50;
    if (request->num_route_params > 0) {
        parse_i64(request->route_params[0].ptr, request->route_params[0].len, &item_count);
    }
    if (item_count < 1) {
        item_count = 1;
    }
    if (item_count > 50) {
        item_count = 50;
    }

    int64_t multiplier = 1;
    str_view_t multiplier_parameter;
    if (req_get_query_param(request, "m", &multiplier_parameter)) {
        parse_i64(multiplier_parameter.ptr, multiplier_parameter.len, &multiplier);
    }

    size_t json_length =
        json_serialize((size_t)item_count, multiplier, worker->compress.json_buf, sizeof(worker->compress.json_buf));

    bool client_accepts_brotli =
        (request->accept_encoding.ptr && strcasestr(request->accept_encoding.ptr, "br") != NULL);
    bool client_accepts_gzip =
        (request->accept_encoding.ptr && strcasestr(request->accept_encoding.ptr, "gzip") != NULL);

    if (client_accepts_gzip) {
        size_t compressed_length = 0;
        if (compress_gzip(&worker->compress, worker->compress.json_buf, json_length, worker->compress.comp_buf,
                          sizeof(worker->compress.comp_buf), &compressed_length) == 0) {
            res_set_json(response, worker->compress.comp_buf, compressed_length);
            response->content_encoding = "gzip";
            return;
        }
    }

    if (client_accepts_brotli) {
        size_t compressed_length = 0;
        if (compress_brotli(worker->compress.json_buf, json_length, worker->compress.comp_buf,
                            sizeof(worker->compress.comp_buf), &compressed_length) == 0) {
            res_set_json(response, worker->compress.comp_buf, compressed_length);
            response->content_encoding = "br";
            return;
        }
    }

    res_set_json(response, worker->compress.json_buf, json_length);
    response->content_encoding = NULL;
}

void echo_handler(context_t *context) {
    request_t *request = context->req;
    response_t *response = context->res;
    res_set_binary(response, request->body.ptr, request->body.len, "application/octet-stream");
}

void handle_timer_expiration(worker_t *worker, conn_t *connection, int64_t delay_milliseconds) {
    connection->parked_in_timer = false;

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
