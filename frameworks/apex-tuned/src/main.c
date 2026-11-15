#include "server.h"
#include "tls.h"
#include "static_files.h"
#include "h2.h"

static volatile bool g_running = true;
static int g_num_workers = 1;
static worker_t *g_workers = NULL;
static __thread worker_t *t_worker = NULL;

static void handle_sig(int signal_number) {
    (void)signal_number;
    _exit(0);
}

static inline void conn_list_insert_tail(worker_t *worker, conn_t *connection) {
    connection->active_prev = worker->active_tail;
    connection->active_next = NULL;
    if (worker->active_tail) {
        worker->active_tail->active_next = connection;
    } else {
        worker->active_head = connection;
    }
    worker->active_tail = connection;
}

static inline void conn_list_remove(worker_t *worker, conn_t *connection) {
    if (connection->active_prev || connection->active_next || worker->active_head == connection ||
        worker->active_tail == connection) {
        if (connection->active_prev) {
            connection->active_prev->active_next = connection->active_next;
        } else if (worker->active_head == connection) {
            worker->active_head = connection->active_next;
        }
        if (connection->active_next) {
            connection->active_next->active_prev = connection->active_prev;
        } else if (worker->active_tail == connection) {
            worker->active_tail = connection->active_prev;
        }
        connection->active_prev = NULL;
        connection->active_next = NULL;
    }
}

static inline void conn_touch(worker_t *worker, conn_t *connection, uint64_t current_time_ms) {
    connection->last_active_ms = current_time_ms;
    if (worker->active_tail == connection) {
        return;
    }
    conn_list_remove(worker, connection);
    conn_list_insert_tail(worker, connection);
}

static conn_t *alloc_conn(worker_t *worker, int client_fd, bool is_tls, SSL *ssl_session) {
    conn_t *connection = worker->free_conns;
    if (connection) {
        worker->free_conns = connection->next_free;
    } else {
        connection = calloc(1, sizeof(conn_t));
        if (!connection) {
            return NULL;
        }
        connection->read_buf = connection->inline_read_buf;
        connection->read_cap = sizeof(connection->inline_read_buf);
    }
    connection->fd = client_fd;
    connection->gen++;
    connection->is_tls = is_tls;
    connection->ssl = ssl_session;
    connection->tls_handshake_done = false;
    connection->read_pos = 0;
    connection->pending_write = NULL;
    connection->pending_write_len = 0;
    connection->pending_write_sent = 0;
    connection->is_h2 = false;
    connection->h2 = NULL;
    connection->parked_in_timer = false;
    connection->keep_alive = true;
    connection->closing = false;
    connection->next_free = NULL;
    connection->active_prev = NULL;
    connection->active_next = NULL;
    connection->last_active_ms = clock_monotonic_ms();
    conn_list_insert_tail(worker, connection);
    return connection;
}

void close_conn(worker_t *worker, conn_t *connection) {
    conn_list_remove(worker, connection);
    if (connection->is_h2) {
        h2_connection_destroy(connection);
        connection->is_h2 = false;
    }
    if (connection->fd >= 0) {
        epoll_ctl(worker->epoll_fd, EPOLL_CTL_DEL, connection->fd, NULL);
        close(connection->fd);
        connection->fd = -1;
    }
    if (connection->ssl) {
        SSL_free(connection->ssl);
        connection->ssl = NULL;
    }
    if (connection->pending_write) {
        free(connection->pending_write);
        connection->pending_write = NULL;
    }
    if (connection->read_buf != connection->inline_read_buf) {
        free(connection->read_buf);
        connection->read_buf = connection->inline_read_buf;
        connection->read_cap = sizeof(connection->inline_read_buf);
    }
    connection->read_pos = 0;
    connection->pending_write_len = 0;
    connection->pending_write_sent = 0;
    connection->parked_in_timer = false;
    connection->closing = false;
    connection->gen++;

    connection->next_free = worker->free_conns;
    worker->free_conns = connection;
}

static void baseline_handler(context_t *context) {
    request_t *request = context->req;
    response_t *response = context->res;
    conn_t *connection = (conn_t *)context->user_data;

    int64_t accumulated_sum = 0;
    for (size_t i = 0; i < request->num_params; i++) {
        int64_t parameter_value = 0;
        if (parse_i64(request->params[i].val.ptr, request->params[i].val.len, &parameter_value)) {
            accumulated_sum += parameter_value;
        }
    }

    if (request->method == HTTP_METHOD_POST && request->body.len > 0) {
        int64_t body_value = 0;
        if (parse_i64(request->body.ptr, request->body.len, &body_value)) {
            accumulated_sum += body_value;
        }
    }

    size_t formatted_length = format_i64(connection->scratch, accumulated_sum);
    res_set_text(response, connection->scratch, formatted_length);
}

static void pipeline_handler(context_t *context) {
    res_set_text(context->res, "ok", 2);
}

static void delay_handler(context_t *context) {
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
        size_t formatted_length = format_i64(connection->scratch, 0);
        res_set_text(response, connection->scratch, formatted_length);
        return;
    }

    connection->parked_in_timer = true;
    connection->timer_expire_us = clock_monotonic_us() + (uint64_t)delay_milliseconds * 1000ULL;
    connection->timer_val_ms = delay_milliseconds;
    connection->keep_alive = request->keep_alive;
    context->async_parked = true;
}

static void json_handler(context_t *context) {
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

static void echo_handler(context_t *context) {
    request_t *request = context->req;
    response_t *response = context->res;
    res_set_binary(response, request->body.ptr, request->body.len, "application/octet-stream");
}

static bool flush_pending_write(worker_t *worker, conn_t *connection) {
    while (connection->pending_write_sent < connection->pending_write_len) {
        size_t remaining_bytes = connection->pending_write_len - connection->pending_write_sent;
        ssize_t bytes_sent = 0;
        if (connection->is_tls) {
            int write_status = SSL_write(connection->ssl, connection->pending_write + connection->pending_write_sent,
                                         (int)remaining_bytes);
            if (write_status <= 0) {
                int ssl_error = SSL_get_error(connection->ssl, write_status);
                if (ssl_error == SSL_ERROR_WANT_WRITE || ssl_error == SSL_ERROR_WANT_READ) {
                    return false;
                }
                close_conn(worker, connection);
                return false;
            }
            bytes_sent = write_status;
        } else {
            bytes_sent = send(connection->fd, connection->pending_write + connection->pending_write_sent,
                              remaining_bytes, MSG_NOSIGNAL | MSG_DONTWAIT);
            if (bytes_sent < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    return false;
                }
                close_conn(worker, connection);
                return false;
            }
        }
        connection->pending_write_sent += (size_t)bytes_sent;
    }

    free(connection->pending_write);
    connection->pending_write = NULL;
    connection->pending_write_len = 0;
    connection->pending_write_sent = 0;

    struct epoll_event event = {.events = EPOLLIN | EPOLLET | EPOLLRDHUP | EPOLLHUP | EPOLLERR, .data.ptr = connection};
    epoll_ctl(worker->epoll_fd, EPOLL_CTL_MOD, connection->fd, &event);

    if (connection->closing || !connection->keep_alive) {
        close_conn(worker, connection);
        return false;
    }

    return true;
}

void flush_data(worker_t *worker, conn_t *connection, const char *data, size_t length) {
    if (length == 0) {
        return;
    }
    size_t total_sent_bytes = 0;

    while (total_sent_bytes < length) {
        ssize_t bytes_sent = 0;
        if (connection->is_tls) {
            int write_status = SSL_write(connection->ssl, data + total_sent_bytes, (int)(length - total_sent_bytes));
            if (write_status <= 0) {
                int ssl_error = SSL_get_error(connection->ssl, write_status);
                if (ssl_error == SSL_ERROR_WANT_WRITE || ssl_error == SSL_ERROR_WANT_READ) {
                    break;
                }
                close_conn(worker, connection);
                return;
            }
            bytes_sent = write_status;
        } else {
            bytes_sent =
                send(connection->fd, data + total_sent_bytes, length - total_sent_bytes, MSG_NOSIGNAL | MSG_DONTWAIT);
            if (bytes_sent < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    break;
                }
                close_conn(worker, connection);
                return;
            }
        }
        total_sent_bytes += (size_t)bytes_sent;
    }

    if (total_sent_bytes < length) {
        size_t unsent_bytes = length - total_sent_bytes;
        connection->pending_write = malloc(unsent_bytes);
        if (!connection->pending_write) {
            close_conn(worker, connection);
            return;
        }
        memcpy(connection->pending_write, data + total_sent_bytes, unsent_bytes);
        connection->pending_write_len = unsent_bytes;
        connection->pending_write_sent = 0;

        struct epoll_event event = {.events = EPOLLIN | EPOLLOUT | EPOLLET | EPOLLRDHUP | EPOLLHUP | EPOLLERR,
                                    .data.ptr = connection};
        epoll_ctl(worker->epoll_fd, EPOLL_CTL_MOD, connection->fd, &event);
        return;
    }

    if (connection->closing || !connection->keep_alive) {
        close_conn(worker, connection);
    }
}

static inline int64_t parse_integer_fast(const char *buffer, size_t length) {
    const char *cursor = buffer;
    const char *end_cursor = buffer + length;
    while (cursor < end_cursor && (*cursor == ' ' || *cursor == '\t' || *cursor == '\r' || *cursor == '\n')) {
        cursor++;
    }
    int sign_multiplier = 1;
    if (cursor < end_cursor && *cursor == '-') {
        sign_multiplier = -1;
        cursor++;
    }
    int64_t accumulated_value = 0;
    while (cursor < end_cursor && *cursor >= '0' && *cursor <= '9') {
        accumulated_value = accumulated_value * 10 + (*cursor - '0');
        cursor++;
    }
    return sign_multiplier * accumulated_value;
}

static inline int64_t calculate_query_integer_sum_fast(const char *query_buffer, size_t query_length) {
    const char *cursor = query_buffer;
    const char *end_cursor = query_buffer + query_length;
    int64_t accumulated_sum = 0;

    while (cursor < end_cursor) {
        const char *equals_separator = memchr(cursor, '=', (size_t)(end_cursor - cursor));
        if (!equals_separator) {
            break;
        }
        const char *value_cursor = equals_separator + 1;
        const char *ampersand_separator = memchr(value_cursor, '&', (size_t)(end_cursor - value_cursor));
        const char *value_end = ampersand_separator ? ampersand_separator : end_cursor;

        while (value_cursor < value_end && (*value_cursor == ' ' || *value_cursor == '\t')) {
            value_cursor++;
        }
        int sign_multiplier = 1;
        if (value_cursor < value_end && *value_cursor == '-') {
            sign_multiplier = -1;
            value_cursor++;
        }
        int64_t integer_value = 0;
        while (value_cursor < value_end && *value_cursor >= '0' && *value_cursor <= '9') {
            integer_value = integer_value * 10 + (*value_cursor - '0');
            value_cursor++;
        }
        accumulated_sum += sign_multiplier * integer_value;
        cursor = ampersand_separator ? ampersand_separator + 1 : end_cursor;
    }
    return accumulated_sum;
}

static inline size_t format_plain_text_pipeline_response(char *destination_buffer, bool is_keep_alive,
                                                         bool *out_is_closing_requested) {
    if (__builtin_expect(is_keep_alive, 1)) {
        static const char response_pipeline_keep_alive[] =
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: keep-alive\r\nContent-Length: 2\r\n\r\nok";
        memcpy(destination_buffer, response_pipeline_keep_alive, sizeof(response_pipeline_keep_alive) - 1);
        return sizeof(response_pipeline_keep_alive) - 1;
    } else {
        static const char response_pipeline_close[] =
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: 2\r\n\r\nok";
        memcpy(destination_buffer, response_pipeline_close, sizeof(response_pipeline_close) - 1);
        *out_is_closing_requested = true;
        return sizeof(response_pipeline_close) - 1;
    }
}

static inline size_t format_plain_text_baseline_response(char *destination_buffer, int64_t sum_value,
                                                         bool is_keep_alive, bool *out_is_closing_requested) {
    char number_buffer[32];
    size_t number_length = (size_t)format_i64(number_buffer, sum_value);
    char *cursor = destination_buffer;

    if (__builtin_expect(is_keep_alive, 1)) {
        static const char header_keep_alive[] =
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: keep-alive\r\nContent-Length: ";
        memcpy(cursor, header_keep_alive, sizeof(header_keep_alive) - 1);
        cursor += sizeof(header_keep_alive) - 1;
        cursor += format_i64(cursor, (int64_t)number_length);
        *cursor++ = '\r';
        *cursor++ = '\n';
        *cursor++ = '\r';
        *cursor++ = '\n';
        memcpy(cursor, number_buffer, number_length);
        cursor += number_length;
    } else {
        static const char header_close[] =
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: ";
        memcpy(cursor, header_close, sizeof(header_close) - 1);
        cursor += sizeof(header_close) - 1;
        cursor += format_i64(cursor, (int64_t)number_length);
        *cursor++ = '\r';
        *cursor++ = '\n';
        *cursor++ = '\r';
        *cursor++ = '\n';
        memcpy(cursor, number_buffer, number_length);
        cursor += number_length;
        *out_is_closing_requested = true;
    }
    return (size_t)(cursor - destination_buffer);
}

static void process_requests(worker_t *worker, conn_t *connection) {
    size_t write_pos = 0;
    size_t read_offset = 0;

    while (connection->read_pos > read_offset && !connection->parked_in_timer && !connection->closing) {
        request_t request;
        size_t consumed_bytes = 0;
        int parse_status = parse_http_request(connection->read_buf + read_offset, connection->read_pos - read_offset,
                                              &request, worker->chunk_buf, sizeof(worker->chunk_buf), &consumed_bytes);

        if (parse_status == 0) {
            break;
        }
        if (parse_status < 0) {
            close_conn(worker, connection);
            return;
        }

        connection->keep_alive = request.keep_alive;

        // ── Ultra-fast path for /pipeline ──
        if (__builtin_expect(request.path.len == 9 && memcmp(request.path.ptr, "/pipeline", 9) == 0, 0)) {
            if (sizeof(worker->write_buf) - write_pos < 128) {
                if (write_pos > 0) {
                    flush_data(worker, connection, worker->write_buf, write_pos);
                    write_pos = 0;
                }
            }
            write_pos += format_plain_text_pipeline_response(worker->write_buf + write_pos, connection->keep_alive,
                                                             &connection->closing);
            read_offset += consumed_bytes;
            continue;
        }

        // ── Ultra-fast path for /baseline11 ──
        if (__builtin_expect(request.path.len == 11 && memcmp(request.path.ptr, "/baseline11", 11) == 0, 0)) {
            int64_t accumulated_sum =
                request.query.len > 0 ? calculate_query_integer_sum_fast(request.query.ptr, request.query.len) : 0;
            if (request.method == HTTP_METHOD_POST && request.body.len > 0) {
                accumulated_sum += parse_integer_fast(request.body.ptr, request.body.len);
            }

            if (sizeof(worker->write_buf) - write_pos < 128) {
                if (write_pos > 0) {
                    flush_data(worker, connection, worker->write_buf, write_pos);
                    write_pos = 0;
                }
            }

            write_pos += format_plain_text_baseline_response(worker->write_buf + write_pos, accumulated_sum,
                                                             connection->keep_alive, &connection->closing);
            read_offset += consumed_bytes;
            continue;
        }

        // ── Ultra-fast path for /baseline2 ──
        if (__builtin_expect(request.path.len == 10 && memcmp(request.path.ptr, "/baseline2", 10) == 0, 0)) {
            int64_t accumulated_sum =
                request.query.len > 0 ? calculate_query_integer_sum_fast(request.query.ptr, request.query.len) : 0;

            if (sizeof(worker->write_buf) - write_pos < 128) {
                if (write_pos > 0) {
                    flush_data(worker, connection, worker->write_buf, write_pos);
                    write_pos = 0;
                }
            }

            write_pos += format_plain_text_baseline_response(worker->write_buf + write_pos, accumulated_sum,
                                                             connection->keep_alive, &connection->closing);
            read_offset += consumed_bytes;
            continue;
        }

        response_t response;
        res_init(&response, connection->keep_alive);

        bool is_async_parked = false;
        if (!router_dispatch(&worker->router, &request, &response, connection, &is_async_parked)) {
            res_set_status(&response, 404);
            res_set_text(&response, "Not Found", 9);
        }

        if (is_async_parked) {
            timer_heap_push(&worker->timers, connection->timer_expire_us, connection, connection->gen,
                            connection->timer_val_ms);
            read_offset += consumed_bytes;
            break;
        }

        size_t remaining_space = sizeof(worker->write_buf) - write_pos;
        size_t bytes_written = res_serialize(&response, worker->write_buf + write_pos, remaining_space);
        if (response.body_needs_free && response.body) {
            free((void *)response.body);
        }

        if (bytes_written == 0) {
            close_conn(worker, connection);
            return;
        }

        write_pos += bytes_written;
        read_offset += consumed_bytes;

        if (!connection->keep_alive) {
            connection->closing = true;
        }
    }

    if (read_offset > 0) {
        if (read_offset < connection->read_pos) {
            memmove(connection->read_buf, connection->read_buf + read_offset, connection->read_pos - read_offset);
            connection->read_pos -= read_offset;
        } else {
            connection->read_pos = 0;
        }
    }

    if (write_pos > 0) {
        flush_data(worker, connection, worker->write_buf, write_pos);
    }
}

static void handle_timer_expiration(worker_t *worker, conn_t *connection, int64_t delay_milliseconds) {
    connection->parked_in_timer = false;

    static const char response_delay_10[] = "HTTP/1.1 200 OK\r\n"
                                            "Content-Type: text/plain\r\n"
                                            "Content-Length: 2\r\n"
                                            "Connection: keep-alive\r\n\r\n10";
    static const size_t response_delay_10_length = sizeof(response_delay_10) - 1;

    if (__builtin_expect(delay_milliseconds == 10 && connection->keep_alive, 1)) {
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
        response_t response;
        res_init(&response, connection->keep_alive);
        char number_buffer[24];
        size_t formatted_length = format_i64(number_buffer, delay_milliseconds);
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

static void *worker_main(void *thread_argument) {
    worker_t *worker = (worker_t *)thread_argument;
    t_worker = worker;

#if defined(__linux__) && defined(PR_SET_TIMERSLACK)
    prctl(PR_SET_TIMERSLACK, 1UL, 0, 0, 0);
#endif

    cpu_set_t cpu_set;
    CPU_ZERO(&cpu_set);
    CPU_SET(worker->cpu_id, &cpu_set);
    pthread_setaffinity_np(pthread_self(), sizeof(cpu_set), &cpu_set);

    struct epoll_event epoll_events[MAX_EVENTS];

    while (g_running) {
        uint64_t current_time_us = clock_monotonic_us();

        if (worker->timers.count > 0) {
            timer_entry_t timer_entry;
            while (timer_heap_peek(&worker->timers, &timer_entry)) {
                if (timer_entry.expire_at_us > current_time_us) {
                    break;
                }
                timer_heap_pop(&worker->timers, &timer_entry);
                conn_t *connection = (conn_t *)timer_entry.conn_ptr;
                if (connection && connection->gen == timer_entry.conn_gen && connection->parked_in_timer) {
                    handle_timer_expiration(worker, connection, timer_entry.delay_ms);
                }
            }
        }

        int64_t timeout_us = timer_heap_next_timeout_us(&worker->timers, current_time_us);
        if (timeout_us < 0 || timeout_us > 1000000) {
            timeout_us = 1000000;
        }
        int num_ready_descriptors = 0;

        if (timeout_us <= 350) {
            uint64_t target_time_us = current_time_us + (uint64_t)timeout_us;
            while (true) {
                num_ready_descriptors = epoll_wait(worker->epoll_fd, epoll_events, MAX_EVENTS, 0);
                if (num_ready_descriptors != 0) {
                    break;
                }
                current_time_us = clock_monotonic_us();
                if (current_time_us >= target_time_us) {
                    break;
                }
                for (int spin_count = 0; spin_count < 16; spin_count++) {
#if defined(__x86_64__) || defined(_M_X64)
                    __builtin_ia32_pause();
#elif defined(__aarch64__)
                    asm volatile("yield" ::: "memory");
#endif
                }
            }
        } else {
            int64_t sleep_us = timeout_us - 250;
#if defined(__linux__)
            struct timespec timeout_timespec = {.tv_sec = (time_t)(sleep_us / 1000000),
                                                .tv_nsec = (long)((sleep_us % 1000000) * 1000)};
            num_ready_descriptors = epoll_pwait2(worker->epoll_fd, epoll_events, MAX_EVENTS, &timeout_timespec, NULL);
            if (num_ready_descriptors < 0 && errno == ENOSYS) {
                int timeout_ms = (int)(sleep_us / 1000);
                if (timeout_ms < 1) {
                    timeout_ms = 1;
                }
                num_ready_descriptors = epoll_wait(worker->epoll_fd, epoll_events, MAX_EVENTS, timeout_ms);
            }
#else
            int timeout_ms = (int)(sleep_us / 1000);
            if (timeout_ms < 1) {
                timeout_ms = 1;
            }
            num_ready_descriptors = epoll_wait(worker->epoll_fd, epoll_events, MAX_EVENTS, timeout_ms);
#endif
        }

        if (num_ready_descriptors < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }

        uint64_t current_time_ms = clock_monotonic_ms();

        // Reap connections idle for >= 15 seconds
        while (worker->active_head) {
            conn_t *oldest_connection = worker->active_head;
            if (current_time_ms - oldest_connection->last_active_ms < 15000) {
                break;
            }
            if (oldest_connection->parked_in_timer) {
                oldest_connection->last_active_ms = current_time_ms;
                if (worker->active_head != worker->active_tail) {
                    conn_list_remove(worker, oldest_connection);
                    conn_list_insert_tail(worker, oldest_connection);
                    continue;
                }
                break;
            }
            close_conn(worker, oldest_connection);
        }

#if defined(__linux__)
        if (worker->id == 0 && (current_time_ms - worker->last_trim_ms >= 5000)) {
            worker->last_trim_ms = current_time_ms;
            malloc_trim(0);
        }
#endif

        if (worker->timers.count > 0) {
            current_time_us = clock_monotonic_us();
            timer_entry_t timer_entry;
            while (timer_heap_peek(&worker->timers, &timer_entry)) {
                if (timer_entry.expire_at_us > current_time_us) {
                    break;
                }
                timer_heap_pop(&worker->timers, &timer_entry);
                conn_t *connection = (conn_t *)timer_entry.conn_ptr;
                if (connection && connection->gen == timer_entry.conn_gen && connection->parked_in_timer) {
                    handle_timer_expiration(worker, connection, timer_entry.delay_ms);
                }
            }
        }

        for (int event_index = 0; event_index < num_ready_descriptors; event_index++) {
            void *event_data_ptr = epoll_events[event_index].data.ptr;
            uint32_t event_flags = epoll_events[event_index].events;

            if (event_data_ptr == &worker->token_h1) {
                while (true) {
                    int client_fd = accept4(worker->listen_h1_fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
                    if (client_fd < 0) {
                        break;
                    }

                    set_sock_opts(client_fd);
                    conn_t *connection = alloc_conn(worker, client_fd, false, NULL);
                    if (!connection) {
                        close(client_fd);
                        continue;
                    }

                    struct epoll_event event = {.events = EPOLLIN | EPOLLET | EPOLLRDHUP | EPOLLHUP | EPOLLERR,
                                                .data.ptr = connection};
                    epoll_ctl(worker->epoll_fd, EPOLL_CTL_ADD, client_fd, &event);
                }
                continue;
            }

            if (worker->listen_tls_fd >= 0 && event_data_ptr == &worker->token_tls) {
                while (true) {
                    int client_fd = accept4(worker->listen_tls_fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
                    if (client_fd < 0) {
                        break;
                    }

                    set_sock_opts(client_fd);
                    SSL *ssl_session = SSL_new(worker->ssl_ctx);
                    if (!ssl_session) {
                        close(client_fd);
                        continue;
                    }
                    SSL_set_fd(ssl_session, client_fd);
                    SSL_set_accept_state(ssl_session);

                    conn_t *connection = alloc_conn(worker, client_fd, true, ssl_session);
                    if (!connection) {
                        SSL_free(ssl_session);
                        close(client_fd);
                        continue;
                    }

                    struct epoll_event event = {.events =
                                                    EPOLLIN | EPOLLOUT | EPOLLET | EPOLLRDHUP | EPOLLHUP | EPOLLERR,
                                                .data.ptr = connection};
                    epoll_ctl(worker->epoll_fd, EPOLL_CTL_ADD, client_fd, &event);
                }
                continue;
            }

            if (worker->listen_h2c_fd >= 0 && event_data_ptr == &worker->token_h2c) {
                while (true) {
                    int client_fd = accept4(worker->listen_h2c_fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
                    if (client_fd < 0) {
                        break;
                    }

                    set_sock_opts(client_fd);
                    conn_t *connection = alloc_conn(worker, client_fd, false, NULL);
                    if (!connection) {
                        close(client_fd);
                        continue;
                    }

                    connection->is_h2 = true;
                    if (!h2_connection_init(connection, worker)) {
                        close_conn(worker, connection);
                        continue;
                    }

                    struct epoll_event event = {.events = EPOLLIN | EPOLLET | EPOLLRDHUP | EPOLLHUP | EPOLLERR,
                                                .data.ptr = connection};
                    epoll_ctl(worker->epoll_fd, EPOLL_CTL_ADD, client_fd, &event);
                }
                continue;
            }

            if (worker->listen_h2_fd >= 0 && event_data_ptr == &worker->token_h2) {
                while (true) {
                    int client_fd = accept4(worker->listen_h2_fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
                    if (client_fd < 0) {
                        break;
                    }

                    set_sock_opts(client_fd);
                    SSL *ssl_session = SSL_new(worker->ssl_ctx_h2);
                    if (!ssl_session) {
                        close(client_fd);
                        continue;
                    }
                    SSL_set_fd(ssl_session, client_fd);
                    SSL_set_accept_state(ssl_session);

                    conn_t *connection = alloc_conn(worker, client_fd, true, ssl_session);
                    if (!connection) {
                        SSL_free(ssl_session);
                        close(client_fd);
                        continue;
                    }

                    struct epoll_event event = {.events =
                                                    EPOLLIN | EPOLLOUT | EPOLLET | EPOLLRDHUP | EPOLLHUP | EPOLLERR,
                                                .data.ptr = connection};
                    epoll_ctl(worker->epoll_fd, EPOLL_CTL_ADD, client_fd, &event);
                }
                continue;
            }

            conn_t *connection = (conn_t *)event_data_ptr;
            if (!connection || connection->fd < 0) {
                continue;
            }

            if (event_flags & (EPOLLRDHUP | EPOLLHUP | EPOLLERR)) {
                close_conn(worker, connection);
                continue;
            }

            conn_touch(worker, connection, current_time_ms);

            if (connection->is_tls && !connection->tls_handshake_done) {
                int handshake_status = SSL_accept(connection->ssl);
                if (handshake_status <= 0) {
                    int ssl_error = SSL_get_error(connection->ssl, handshake_status);
                    if (ssl_error == SSL_ERROR_WANT_READ || ssl_error == SSL_ERROR_WANT_WRITE) {
                        continue;
                    }
                    close_conn(worker, connection);
                    continue;
                }
                connection->tls_handshake_done = true;

                const unsigned char *alpn_selected = NULL;
                unsigned int alpn_length = 0;
                SSL_get0_alpn_selected(connection->ssl, &alpn_selected, &alpn_length);
                if (alpn_selected && alpn_length == 2 && memcmp(alpn_selected, "h2", 2) == 0) {
                    connection->is_h2 = true;
                    if (!h2_connection_init(connection, worker)) {
                        close_conn(worker, connection);
                        continue;
                    }
                }

                struct epoll_event event = {.events = EPOLLIN | EPOLLET | EPOLLRDHUP | EPOLLHUP | EPOLLERR,
                                            .data.ptr = connection};
                epoll_ctl(worker->epoll_fd, EPOLL_CTL_MOD, connection->fd, &event);
            }

            if (event_flags & EPOLLOUT) {
                if (connection->pending_write) {
                    if (!flush_pending_write(worker, connection)) {
                        continue;
                    }
                }
            }

            if (event_flags & EPOLLIN) {
                if (connection->is_h2) {
                    char h2_read_buffer[65536];
                    while (true) {
                        ssize_t bytes_read = 0;
                        if (connection->is_tls) {
                            int read_status = SSL_read(connection->ssl, h2_read_buffer, sizeof(h2_read_buffer));
                            if (read_status <= 0) {
                                int ssl_error = SSL_get_error(connection->ssl, read_status);
                                if (ssl_error == SSL_ERROR_WANT_READ || ssl_error == SSL_ERROR_WANT_WRITE) {
                                    break;
                                }
                                close_conn(worker, connection);
                                break;
                            }
                            bytes_read = read_status;
                        } else {
                            bytes_read = recv(connection->fd, h2_read_buffer, sizeof(h2_read_buffer), MSG_DONTWAIT);
                            if (bytes_read < 0) {
                                if (errno == EAGAIN || errno == EWOULDBLOCK) {
                                    break;
                                }
                                close_conn(worker, connection);
                                break;
                            }
                            if (bytes_read == 0) {
                                close_conn(worker, connection);
                                break;
                            }
                        }
                        if (!h2_connection_process_incoming_data(connection, worker, h2_read_buffer,
                                                                 (size_t)bytes_read)) {
                            close_conn(worker, connection);
                            break;
                        }
                    }
                    continue;
                }

                while (true) {
                    if (connection->read_pos == connection->read_cap) {
                        size_t new_capacity = connection->read_cap * 2;
                        if (new_capacity < 65536) {
                            new_capacity = 65536;
                        }
                        if (new_capacity > 512 * 1024) {
                            new_capacity = 512 * 1024;
                        }
                        if (new_capacity > connection->read_cap) {
                            char *new_buffer = malloc(new_capacity);
                            if (!new_buffer) {
                                close_conn(worker, connection);
                                break;
                            }
                            memcpy(new_buffer, connection->read_buf, connection->read_pos);
                            if (connection->read_buf != connection->inline_read_buf) {
                                free(connection->read_buf);
                            }
                            connection->read_buf = new_buffer;
                            connection->read_cap = new_capacity;
                        } else {
                            close_conn(worker, connection);
                            break;
                        }
                    }

                    size_t available_space = connection->read_cap - connection->read_pos;
                    ssize_t bytes_read = 0;
                    if (connection->is_tls) {
                        int read_status = SSL_read(connection->ssl, connection->read_buf + connection->read_pos,
                                                   (int)available_space);
                        if (read_status <= 0) {
                            int ssl_error = SSL_get_error(connection->ssl, read_status);
                            if (ssl_error == SSL_ERROR_WANT_READ || ssl_error == SSL_ERROR_WANT_WRITE) {
                                break;
                            }
                            close_conn(worker, connection);
                            break;
                        }
                        bytes_read = read_status;
                    } else {
                        bytes_read = recv(connection->fd, connection->read_buf + connection->read_pos, available_space,
                                          MSG_DONTWAIT);
                        if (bytes_read < 0) {
                            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                                break;
                            }
                            close_conn(worker, connection);
                            break;
                        }
                        if (bytes_read == 0) {
                            close_conn(worker, connection);
                            break;
                        }
                    }
                    connection->read_pos += (size_t)bytes_read;
                    if (connection->read_pos >= 4) {
                        const char *header_end = memmem(connection->read_buf, connection->read_pos, "\r\n\r\n", 4);
                        if (header_end) {
                            size_t header_length = (size_t)(header_end - connection->read_buf) + 4;
                            if (connection->read_buf[0] == 'G' || connection->read_buf[0] == 'H') {
                                break;
                            }
                            const char *content_length_position =
                                memmem(connection->read_buf, header_length, "Content-Length: ", 16);
                            if (!content_length_position) {
                                content_length_position =
                                    memmem(connection->read_buf, header_length, "content-length: ", 16);
                            }
                            if (content_length_position) {
                                int64_t parsed_content_length = 0;
                                if (parse_i64(content_length_position + 16,
                                              (size_t)(header_end - (content_length_position + 16)),
                                              &parsed_content_length) &&
                                    parsed_content_length >= 0) {
                                    if (connection->read_pos >= header_length + (size_t)parsed_content_length) {
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }

                if (connection->fd >= 0 && connection->read_pos > 0) {
                    process_requests(worker, connection);
                }
                if (connection->is_tls) {
                    while (connection->fd >= 0 && !connection->closing && SSL_pending(connection->ssl) > 0) {
                        size_t available_space = connection->read_cap - connection->read_pos;
                        if (available_space == 0) {
                            break;
                        }
                        int read_status = SSL_read(connection->ssl, connection->read_buf + connection->read_pos,
                                                   (int)available_space);
                        if (read_status <= 0) {
                            break;
                        }
                        connection->read_pos += (size_t)read_status;
                        process_requests(worker, connection);
                    }
                }
            }
        }
    }

    close(worker->epoll_fd);
    close(worker->listen_h1_fd);
    if (worker->listen_tls_fd >= 0) {
        close(worker->listen_tls_fd);
    }
    compress_worker_destroy(&worker->compress);
    timer_heap_destroy(&worker->timers);

    conn_t *current_connection = worker->free_conns;
    while (current_connection) {
        conn_t *next_connection = current_connection->next_free;
        if (current_connection->read_buf != current_connection->inline_read_buf) {
            free(current_connection->read_buf);
        }
        if (current_connection->pending_write) {
            free(current_connection->pending_write);
        }
        free(current_connection);
        current_connection = next_connection;
    }
    worker->free_conns = NULL;

    return NULL;
}

static int create_listen_socket(int port_number) {
    int socket_fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (socket_fd < 0) {
        return -1;
    }

    int socket_option_value = 1;
    setsockopt(socket_fd, SOL_SOCKET, SO_REUSEADDR, &socket_option_value, sizeof(socket_option_value));
    setsockopt(socket_fd, SOL_SOCKET, SO_REUSEPORT, &socket_option_value, sizeof(socket_option_value));
#if defined(TCP_DEFER_ACCEPT)
    int defer_accept_seconds = 5;
    setsockopt(socket_fd, IPPROTO_TCP, TCP_DEFER_ACCEPT, &defer_accept_seconds, sizeof(defer_accept_seconds));
#endif
    set_sock_opts(socket_fd);

    struct sockaddr_in socket_address = {
        .sin_family = AF_INET, .sin_port = htons((uint16_t)port_number), .sin_addr.s_addr = INADDR_ANY};

    if (bind(socket_fd, (struct sockaddr *)&socket_address, sizeof(socket_address)) < 0) {
        close(socket_fd);
        return -1;
    }

    if (listen(socket_fd, 65535) < 0) {
        close(socket_fd);
        return -1;
    }

    return socket_fd;
}

int main(void) {
    signal(SIGINT, handle_sig);
    signal(SIGTERM, handle_sig);
    signal(SIGPIPE, SIG_IGN);

    cpu_set_t cpu_affinity_mask;
    int allowed_cpus[MAX_WORKERS];
    int num_allowed_cpus = 0;
    if (sched_getaffinity(0, sizeof(cpu_affinity_mask), &cpu_affinity_mask) == 0) {
        for (int cpu_index = 0; cpu_index < CPU_SETSIZE && num_allowed_cpus < MAX_WORKERS; cpu_index++) {
            if (CPU_ISSET(cpu_index, &cpu_affinity_mask)) {
                allowed_cpus[num_allowed_cpus++] = cpu_index;
            }
        }
    }
    if (num_allowed_cpus == 0) {
        long configured_cpus = sysconf(_SC_NPROCESSORS_ONLN);
        if (configured_cpus <= 0) {
            configured_cpus = 1;
        }
        if (configured_cpus > MAX_WORKERS) {
            configured_cpus = MAX_WORKERS;
        }
        for (int cpu_index = 0; cpu_index < configured_cpus; cpu_index++) {
            allowed_cpus[cpu_index] = cpu_index;
        }
        num_allowed_cpus = (int)configured_cpus;
    }
    g_num_workers = num_allowed_cpus;

    const char *dataset_path = getenv("DATASET_PATH");
    if (!dataset_path) {
        dataset_path = "/data/dataset.json";
    }
    if (!dataset_load(dataset_path)) {
        dataset_load("./data/dataset.json");
    }

    const char *static_root = getenv("STATIC_ROOT");
    if (!static_root) {
        static_root = "/data/static";
    }
    static_files_init(static_root);

    const char *cert_file = getenv("TLS_CERT");
    if (!cert_file) {
        cert_file = "/certs/server.crt";
    }
    const char *key_file = getenv("TLS_KEY");
    if (!key_file) {
        key_file = "/certs/server.key";
    }

    SSL_CTX *shared_ssl_ctx = tls_init_server_ctx(cert_file, key_file, false);
    if (!shared_ssl_ctx) {
        shared_ssl_ctx = tls_init_server_ctx("./certs/server.crt", "./certs/server.key", false);
    }

    SSL_CTX *shared_ssl_ctx_h2 = tls_init_server_ctx(cert_file, key_file, true);
    if (!shared_ssl_ctx_h2) {
        shared_ssl_ctx_h2 = tls_init_server_ctx("./certs/server.crt", "./certs/server.key", true);
    }

    g_workers = calloc((size_t)g_num_workers, sizeof(worker_t));
    if (!g_workers) {
        perror("calloc g_workers");
        return 1;
    }

    int port_http1 = 8080;
    const char *port_env = getenv("PORT");
    if (port_env) {
        int parsed_port = atoi(port_env);
        if (parsed_port > 0) {
            port_http1 = parsed_port;
        }
    }

    int port_tls = 8081;
    const char *tls_port_env = getenv("TLS_PORT");
    if (tls_port_env) {
        int parsed_port = atoi(tls_port_env);
        if (parsed_port > 0) {
            port_tls = parsed_port;
        }
    }

    int port_h2c = 8082;
    const char *h2c_port_env = getenv("H2C_PORT");
    if (h2c_port_env) {
        int parsed_port = atoi(h2c_port_env);
        if (parsed_port > 0) {
            port_h2c = parsed_port;
        }
    }

    int port_http2 = 8443;
    const char *h2_port_env = getenv("H2_PORT");
    if (!h2_port_env) {
        h2_port_env = getenv("H2PORT");
    }
    if (h2_port_env) {
        int parsed_port = atoi(h2_port_env);
        if (parsed_port > 0) {
            port_http2 = parsed_port;
        }
    }

    for (int worker_index = 0; worker_index < g_num_workers; worker_index++) {
        worker_t *worker = &g_workers[worker_index];
        worker->id = worker_index;
        worker->cpu_id = allowed_cpus[worker_index];
        worker->ssl_ctx = shared_ssl_ctx;
        worker->ssl_ctx_h2 = shared_ssl_ctx_h2;

        router_init(&worker->router);
        router_add(&worker->router, HTTP_METHOD_GET, "/", pipeline_handler);
        router_add(&worker->router, HTTP_METHOD_GET, "/baseline11", baseline_handler);
        router_add(&worker->router, HTTP_METHOD_POST, "/baseline11", baseline_handler);
        router_add(&worker->router, HTTP_METHOD_GET, "/pipeline", pipeline_handler);
        router_add(&worker->router, HTTP_METHOD_GET, "/delay/:ms", delay_handler);
        router_add(&worker->router, HTTP_METHOD_GET, "/json/:count", json_handler);
        router_add(&worker->router, HTTP_METHOD_POST, "/echo", echo_handler);
        router_add(&worker->router, HTTP_METHOD_GET, "/static/", static_file_handler);
        router_add(&worker->router, HTTP_METHOD_HEAD, "/static/", static_file_handler);
        router_add(&worker->router, HTTP_METHOD_HEAD, "/", pipeline_handler);

        compress_worker_init(&worker->compress);
        timer_heap_init(&worker->timers, 16384);
        worker->free_conns = NULL;

        for (int pool_index = 0; pool_index < 128; pool_index++) {
            conn_t *preallocated_conn = calloc(1, sizeof(conn_t));
            if (preallocated_conn) {
                preallocated_conn->read_buf = preallocated_conn->inline_read_buf;
                preallocated_conn->read_cap = sizeof(preallocated_conn->inline_read_buf);
                preallocated_conn->fd = -1;
                preallocated_conn->next_free = worker->free_conns;
                worker->free_conns = preallocated_conn;
            }
        }

        worker->epoll_fd = epoll_create1(EPOLL_CLOEXEC);
        worker->listen_h1_fd = create_listen_socket(port_http1);
        worker->token_h1 = 1;
        struct epoll_event event_h1 = {.events = EPOLLIN, .data.ptr = &worker->token_h1};
        epoll_ctl(worker->epoll_fd, EPOLL_CTL_ADD, worker->listen_h1_fd, &event_h1);

        if (worker->ssl_ctx) {
            worker->listen_tls_fd = create_listen_socket(port_tls);
            if (worker->listen_tls_fd >= 0) {
                worker->token_tls = 2;
                struct epoll_event event_tls = {.events = EPOLLIN, .data.ptr = &worker->token_tls};
                epoll_ctl(worker->epoll_fd, EPOLL_CTL_ADD, worker->listen_tls_fd, &event_tls);
            }
        } else {
            worker->listen_tls_fd = -1;
        }

        worker->listen_h2c_fd = create_listen_socket(port_h2c);
        if (worker->listen_h2c_fd >= 0) {
            worker->token_h2c = 3;
            struct epoll_event event_h2c = {.events = EPOLLIN, .data.ptr = &worker->token_h2c};
            epoll_ctl(worker->epoll_fd, EPOLL_CTL_ADD, worker->listen_h2c_fd, &event_h2c);
        }

        if (worker->ssl_ctx_h2) {
            worker->listen_h2_fd = create_listen_socket(port_http2);
            if (worker->listen_h2_fd >= 0) {
                worker->token_h2 = 4;
                struct epoll_event event_h2 = {.events = EPOLLIN, .data.ptr = &worker->token_h2};
                epoll_ctl(worker->epoll_fd, EPOLL_CTL_ADD, worker->listen_h2_fd, &event_h2);
            }
        } else {
            worker->listen_h2_fd = -1;
        }

        pthread_create(&worker->thread, NULL, worker_main, worker);
    }

    printf("[apex] Server listening on port %d (TLS: %d, H2C: %d, H2: %d) with %d workers\n", port_http1,
           shared_ssl_ctx ? port_tls : -1, port_h2c, shared_ssl_ctx_h2 ? port_http2 : -1, g_num_workers);
    fflush(stdout);

    for (int worker_index = 0; worker_index < g_num_workers; worker_index++) {
        pthread_join(g_workers[worker_index].thread, NULL);
    }

    if (shared_ssl_ctx) {
        tls_free_server_ctx(shared_ssl_ctx);
    }
    if (shared_ssl_ctx_h2) {
        tls_free_server_ctx(shared_ssl_ctx_h2);
    }

    free(g_workers);
    return 0;
}
