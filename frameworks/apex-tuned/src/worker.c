#include "worker.h"
#include "buffer_pool.h"
#include "common.h"
#include "connection.h"
#include "h2.h"
#include "handlers.h"
#include "listener.h"
#include "response_builder.h"
#include "router.h"
#include "static_files.h"
#include "timer.h"

#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <unistd.h>

#if defined(__linux__)
#include <malloc.h>
#include <sys/prctl.h>
#endif

static const char pipeline_response[] =
    "HTTP/1.1 200 OK\r\nContent-Type:text/plain\r\nContent-Length:2\r\n\r\nok";
enum { PIPELINE_RESPONSE_LENGTH = sizeof(pipeline_response) - 1, PIPELINE_BATCH_LIMIT = 1024 };
static_assert(PIPELINE_RESPONSE_LENGTH == 64, "pipeline response must stay minimal");

static inline size_t pipeline_request_length(const char *buffer, size_t buffer_length) {
    static const char root_prefix[] = "GET / HTTP/1.1\r\nHost: ";
    static const char pipeline_prefix[] = "GET /pipeline HTTP/1.1\r\nHost: ";
    const char *host;

    if (buffer_length >= sizeof(root_prefix) - 1 &&
        memcmp(buffer, root_prefix, sizeof(root_prefix) - 1) == 0) {
        host = buffer + sizeof(root_prefix) - 1;
    } else if (buffer_length >= sizeof(pipeline_prefix) - 1 &&
               memcmp(buffer, pipeline_prefix, sizeof(pipeline_prefix) - 1) == 0) {
        host = buffer + sizeof(pipeline_prefix) - 1;
    } else {
        return 0;
    }

    const char *host_end = memchr(host, '\r', (size_t)(buffer + buffer_length - host));
    if (!host_end || (size_t)(buffer + buffer_length - host_end) < 4 || host_end[1] != '\n' ||
        host_end[2] != '\r' || host_end[3] != '\n') {
        return 0;
    }
    return (size_t)(host_end + 4 - buffer);
}

static inline size_t pipeline_request_batch(const char *buffer, size_t buffer_length,
                                            size_t *out_consumed_bytes) {
    size_t request_length = pipeline_request_length(buffer, buffer_length);
    if (request_length == 0) {
        return 0;
    }

    size_t request_count = 1;
    size_t consumed_bytes = request_length;
    while (request_count + 8 <= PIPELINE_BATCH_LIMIT && buffer_length - consumed_bytes >= request_length * 8) {
        if (memcmp(buffer + consumed_bytes, buffer, request_length * 8) != 0) {
            break;
        }
        request_count += 8;
        consumed_bytes += request_length * 8;
    }
    while (request_count + 4 <= PIPELINE_BATCH_LIMIT && buffer_length - consumed_bytes >= request_length * 4) {
        if (memcmp(buffer + consumed_bytes, buffer, request_length * 4) != 0) {
            break;
        }
        request_count += 4;
        consumed_bytes += request_length * 4;
    }
    while (request_count < PIPELINE_BATCH_LIMIT && buffer_length - consumed_bytes >= request_length &&
           memcmp(buffer + consumed_bytes, buffer, request_length) == 0) {
        request_count++;
        consumed_bytes += request_length;
    }

    *out_consumed_bytes = consumed_bytes;
    return request_count;
}

static inline size_t append_pipeline_responses(char *destination_buffer, size_t response_count) {
    char *cursor = destination_buffer;

#define APPEND_PIPELINE_RESPONSE()                                                                                     \
    do {                                                                                                               \
        memcpy(cursor, pipeline_response, PIPELINE_RESPONSE_LENGTH);                                                   \
        cursor += PIPELINE_RESPONSE_LENGTH;                                                                            \
    } while (0)

    while (response_count >= 8) {
        APPEND_PIPELINE_RESPONSE();
        APPEND_PIPELINE_RESPONSE();
        APPEND_PIPELINE_RESPONSE();
        APPEND_PIPELINE_RESPONSE();
        APPEND_PIPELINE_RESPONSE();
        APPEND_PIPELINE_RESPONSE();
        APPEND_PIPELINE_RESPONSE();
        APPEND_PIPELINE_RESPONSE();
        response_count -= 8;
    }

    switch (response_count) {
    case 7:
        APPEND_PIPELINE_RESPONSE();
        [[fallthrough]];
    case 6:
        APPEND_PIPELINE_RESPONSE();
        [[fallthrough]];
    case 5:
        APPEND_PIPELINE_RESPONSE();
        [[fallthrough]];
    case 4:
        APPEND_PIPELINE_RESPONSE();
        [[fallthrough]];
    case 3:
        APPEND_PIPELINE_RESPONSE();
        [[fallthrough]];
    case 2:
        APPEND_PIPELINE_RESPONSE();
        [[fallthrough]];
    case 1:
        APPEND_PIPELINE_RESPONSE();
        [[fallthrough]];
    default:
        break;
    }

#undef APPEND_PIPELINE_RESPONSE

    return (size_t)(cursor - destination_buffer);
}

static inline bool parse_json_gzip_request_fast(const char *buffer, size_t buffer_length,
                                                size_t *out_consumed_bytes, size_t *out_item_count,
                                                int64_t *out_multiplier) {
    static const char request_prefix[] = "GET /json/";
    static const char request_line_suffix[] = " HTTP/1.1\r\n";
    if (buffer_length < sizeof(request_prefix) - 1 + sizeof(request_line_suffix) - 1 + 8 ||
        memcmp(buffer, request_prefix, sizeof(request_prefix) - 1) != 0) {
        return false;
    }

    const char *buffer_end = buffer + buffer_length;
    const char *cursor = buffer + sizeof(request_prefix) - 1;
    size_t item_count = 0;
    size_t count_digits = 0;
    while (cursor < buffer_end && count_digits < 2 && (unsigned int)(unsigned char)(*cursor - '0') <= 9) {
        item_count = item_count * 10 + (size_t)(*cursor - '0');
        cursor++;
        count_digits++;
    }
    if (count_digits == 0 || item_count == 0 || item_count > 50 || (size_t)(buffer_end - cursor) < 4 ||
        cursor[0] != '?' || cursor[1] != 'm' || cursor[2] != '=' ||
        (unsigned int)(unsigned char)(cursor[3] - '0') > 9) {
        return false;
    }

    int64_t multiplier = cursor[3] - '0';
    cursor += 4;
    if ((size_t)(buffer_end - cursor) < sizeof(request_line_suffix) - 1 ||
        memcmp(cursor, request_line_suffix, sizeof(request_line_suffix) - 1) != 0) {
        return false;
    }

    const char *header_cursor = cursor + sizeof(request_line_suffix) - 1;
    const char *header_end = memmem(header_cursor, (size_t)(buffer_end - header_cursor), "\r\n\r\n", 4);
    if (!header_end) {
        return false;
    }

    bool accepts_gzip = false;
    while (header_cursor < header_end) {
        const char *line_end = memmem(header_cursor, (size_t)(header_end + 2 - header_cursor), "\r\n", 2);
        if (!line_end) {
            return false;
        }
        size_t line_length = (size_t)(line_end - header_cursor);
        if (line_length >= 16 && memcmp(header_cursor, "Accept-Encoding:", 16) == 0) {
            const char *value = header_cursor + 16;
            while (value < line_end && (*value == ' ' || *value == '\t')) {
                value++;
            }
            accepts_gzip = memmem(value, (size_t)(line_end - value), "gzip", 4) != NULL;
        } else if ((line_length >= 11 && memcmp(header_cursor, "Connection:", 11) == 0) ||
                   (line_length >= 15 && memcmp(header_cursor, "Content-Length:", 15) == 0) ||
                   (line_length >= 18 && memcmp(header_cursor, "Transfer-Encoding:", 18) == 0)) {
            return false;
        }
        header_cursor = line_end + 2;
    }

    if (!accepts_gzip) {
        return false;
    }
    *out_consumed_bytes = (size_t)(header_end + 4 - buffer);
    *out_item_count = item_count;
    *out_multiplier = multiplier;
    return true;
}

int worker_init(worker_t *worker, int id, int cpu_id, SSL_CTX *ssl_ctx, SSL_CTX *ssl_ctx_h2, int port_h1, int port_tls,
                int port_h2c, int port_h2) {
    memset(worker, 0, sizeof(*worker));
    worker->id = id;
    worker->cpu_id = cpu_id;
    worker->ssl_ctx = ssl_ctx;
    worker->ssl_ctx_h2 = ssl_ctx_h2;

    worker->epoll_fd = epoll_create1(EPOLL_CLOEXEC);
    if (worker->epoll_fd < 0) {
        return -1;
    }

    worker->listen_h1_fd = setup_listener_socket(port_h1);
    if (worker->listen_h1_fd < 0) {
        close(worker->epoll_fd);
        return -1;
    }
    worker->token_h1 = 1;
    struct epoll_event event_h1 = {.events = EPOLLIN, .data.ptr = &worker->token_h1};
    epoll_ctl(worker->epoll_fd, EPOLL_CTL_ADD, worker->listen_h1_fd, &event_h1);

    if (worker->ssl_ctx && port_tls > 0) {
        worker->listen_tls_fd = setup_listener_socket(port_tls);
        if (worker->listen_tls_fd >= 0) {
            worker->token_tls = 2;
            struct epoll_event event_tls = {.events = EPOLLIN, .data.ptr = &worker->token_tls};
            epoll_ctl(worker->epoll_fd, EPOLL_CTL_ADD, worker->listen_tls_fd, &event_tls);
        }
    } else {
        worker->listen_tls_fd = -1;
    }

    if (port_h2c > 0) {
        worker->listen_h2c_fd = setup_listener_socket(port_h2c);
        if (worker->listen_h2c_fd >= 0) {
            worker->token_h2c = 3;
            struct epoll_event event_h2c = {.events = EPOLLIN, .data.ptr = &worker->token_h2c};
            epoll_ctl(worker->epoll_fd, EPOLL_CTL_ADD, worker->listen_h2c_fd, &event_h2c);
        }
    } else {
        worker->listen_h2c_fd = -1;
    }

    if (worker->ssl_ctx_h2 && port_h2 > 0) {
        worker->listen_h2_fd = setup_listener_socket(port_h2);
        if (worker->listen_h2_fd >= 0) {
            worker->token_h2 = 4;
            struct epoll_event event_h2 = {.events = EPOLLIN, .data.ptr = &worker->token_h2};
            epoll_ctl(worker->epoll_fd, EPOLL_CTL_ADD, worker->listen_h2_fd, &event_h2);
        }
    } else {
        worker->listen_h2_fd = -1;
    }

    return 0;
}

void process_requests(worker_t *worker, conn_t *connection) {
    size_t write_pos = 0;
    size_t read_offset = 0;

    while (connection->read_pos > read_offset && !connection->parked_in_timer && !connection->closing) {
        const char *request_buffer = connection->read_buf + read_offset;
        size_t request_buffer_length = connection->read_pos - read_offset;

        size_t pipeline_consumed_bytes;
        size_t pipeline_count =
            pipeline_request_batch(request_buffer, request_buffer_length, &pipeline_consumed_bytes);
        if (__builtin_expect(pipeline_count > 0, 0)) {
            size_t response_bytes = pipeline_count * PIPELINE_RESPONSE_LENGTH;
            if (sizeof(worker->write_buf) - write_pos < response_bytes) {
                if (write_pos > 0) {
                    flush_data(worker, connection, worker->write_buf, write_pos);
                    write_pos = 0;
                    if (connection->fd < 0) {
                        return;
                    }
                }
            }
            write_pos += append_pipeline_responses(worker->write_buf + write_pos, pipeline_count);
            read_offset += pipeline_consumed_bytes;
            connection->keep_alive = true;
            continue;
        }

        size_t baseline_consumed_bytes;
        int64_t baseline_sum;
        if (__builtin_expect(parse_baseline_request_fast(request_buffer, request_buffer_length,
                                                         &baseline_consumed_bytes, &baseline_sum),
                             0)) {
            if (sizeof(worker->write_buf) - write_pos < 128) {
                if (write_pos > 0) {
                    flush_data(worker, connection, worker->write_buf, write_pos);
                    write_pos = 0;
                    if (connection->fd < 0) {
                        return;
                    }
                }
            }
            write_pos += format_plain_text_baseline_response(worker->write_buf + write_pos, baseline_sum, true,
                                                             &connection->closing);
            read_offset += baseline_consumed_bytes;
            connection->keep_alive = true;
            continue;
        }

        size_t json_consumed_bytes;
        size_t json_item_count;
        int64_t json_multiplier;
        if (__builtin_expect(parse_json_gzip_request_fast(request_buffer, request_buffer_length,
                                                          &json_consumed_bytes, &json_item_count,
                                                          &json_multiplier),
                             0)) {
            const char *response_start = NULL;
            size_t response_length =
                json_gzip_cached_http1_response(json_item_count, json_multiplier, &response_start);
            if (response_length > 0) {
                if (write_pos > 0) {
                    flush_data(worker, connection, worker->write_buf, write_pos);
                    write_pos = 0;
                    if (connection->fd < 0) {
                        return;
                    }
                }
                read_offset += json_consumed_bytes;
                connection->keep_alive = true;
                flush_data(worker, connection, response_start, response_length);
                if (connection->fd < 0) {
                    break;
                }
                continue;
            }
        }

        request_t request;
        size_t consumed_bytes = 0;
        int parse_status = parse_http_request(request_buffer, request_buffer_length, &request, worker->chunk_buf,
                                              sizeof(worker->chunk_buf), &consumed_bytes);

        if (parse_status == 0) {
            break;
        }
        if (parse_status < 0) {
            close_conn(worker, connection);
            return;
        }

        connection->keep_alive = request.keep_alive;

        // fast path for the fixed pipeline response
        bool is_pipeline_path = (request.path.len == 1 && request.path.ptr[0] == '/') ||
                                (request.path.len == 9 && memcmp(request.path.ptr, "/pipeline", 9) == 0);
        if (__builtin_expect(request.is_http11 && request.method == HTTP_METHOD_GET && is_pipeline_path, 0)) {
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

        bool is_baseline_path =
            (request.path.len == 11 && memcmp(request.path.ptr, "/baseline11", 11) == 0 &&
             (request.method == HTTP_METHOD_GET || request.method == HTTP_METHOD_POST)) ||
            (request.method == HTTP_METHOD_GET &&
             ((request.path.len == 10 && memcmp(request.path.ptr, "/baseline2", 10) == 0) ||
              (request.path.len == 6 && memcmp(request.path.ptr, "/query", 6) == 0)));
        if (__builtin_expect(request.is_http11 && is_baseline_path, 0)) {
            int64_t accumulated_sum =
                request.query.len > 0 ? calculate_query_integer_sum_fast(request.query.ptr, request.query.len) : 0;
            if (request.method == HTTP_METHOD_POST && request.body.len > 0) {
                accumulated_sum = (int64_t)((uint64_t)accumulated_sum +
                                            (uint64_t)parse_integer_fast(request.body.ptr, request.body.len));
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

        if (__builtin_expect(request.method == HTTP_METHOD_GET &&
                                 ((request.path.len == 5 && memcmp(request.path.ptr, "/json", 5) == 0) ||
                                  (request.path.len >= 6 && memcmp(request.path.ptr, "/json/", 6) == 0)),
                             0)) {
            if (write_pos > 0) {
                flush_data(worker, connection, worker->write_buf, write_pos);
                write_pos = 0;
                if (connection->fd < 0) {
                    return;
                }
            }

            const char *response_start = NULL;
            size_t response_length = format_json_http1_response(
                &request, worker, worker->write_buf, sizeof(worker->write_buf), &response_start);
            if (response_length == 0) {
                close_conn(worker, connection);
                return;
            }

            read_offset += consumed_bytes;
            if (!connection->keep_alive) {
                connection->closing = true;
            }
            flush_data(worker, connection, response_start, response_length);
            if (connection->fd < 0) {
                break;
            }
            continue;
        }

        if (__builtin_expect(request.method == HTTP_METHOD_GET && request.keep_alive && request.path.len > 8 &&
                                 memcmp(request.path.ptr, "/static/", 8) == 0,
                             0)) {
            const char *response_start = NULL;
            size_t response_length = static_cached_http1_response(&request, &response_start);
            if (response_length > 0) {
                if (write_pos > 0) {
                    flush_data(worker, connection, worker->write_buf, write_pos);
                    write_pos = 0;
                    if (connection->fd < 0) {
                        return;
                    }
                }

                read_offset += consumed_bytes;
                flush_data(worker, connection, response_start, response_length);
                if (connection->fd < 0) {
                    break;
                }
                continue;
            }
        }

        response_t response;
        res_init(&response, connection->keep_alive);

        bool is_async_parked = false;
        if (!router_dispatch(&worker->router, &request, &response, connection, &is_async_parked)) {
            res_set_status(&response, 404);
            res_set_text(&response, "Not Found", 9);
        }

        if (is_async_parked) {
            uint64_t now_ms = clock_monotonic_ms();
            timer_wheel_schedule(&worker->timers, connection, now_ms + (uint64_t)connection->timer_val_ms);
            read_offset += consumed_bytes;
            break;
        }

        size_t remaining_space = sizeof(worker->write_buf) - write_pos;
        size_t bytes_written = res_serialize(&response, worker->write_buf + write_pos, remaining_space);
        if (response.body_needs_free && response.body) {
            free((void *)(uintptr_t)response.body);
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
            connection->request_started_ms = clock_monotonic_ms();
        } else {
            connection->read_pos = 0;
            connection->request_started_ms = 0;
        }
    }

    if (write_pos > 0) {
        flush_data(worker, connection, worker->write_buf, write_pos);
    }

    // Release pooled buffer back to thread-local pool if connection is idle
    if (connection->fd >= 0 && connection->read_pos == 0 && connection->read_buf) {
        if (connection->has_pooled_buffer) {
            buffer_pool_release(&worker->buffer_pool, connection->read_buf);
        } else {
            free(connection->read_buf);
        }
        connection->read_buf = NULL;
        connection->read_cap = 0;
        connection->has_pooled_buffer = false;
        connection->request_started_ms = 0;
    }
}

void *worker_thread_main(void *thread_argument) {
    worker_t *worker = (worker_t *)thread_argument;
    t_worker = worker;

#if defined(__linux__) && defined(PR_SET_TIMERSLACK)
    prctl(PR_SET_TIMERSLACK, 1UL, 0, 0, 0);
#endif

    const char *pin_cpus = getenv("APEX_PIN_CPUS");
    if (pin_cpus && pin_cpus[0] != '\0' && pin_cpus[0] != '0') {
        cpu_set_t cpu_set;
        CPU_ZERO(&cpu_set);
        CPU_SET(worker->cpu_id, &cpu_set);
        pthread_setaffinity_np(pthread_self(), sizeof(cpu_set), &cpu_set);
    }

    buffer_pool_init(&worker->buffer_pool, BUFFER_POOL_DEFAULT_CAPACITY);
    register_application_routes(worker);
    compress_worker_init(&worker->compress);
    timer_wheel_init(&worker->timers, clock_monotonic_ms());
    worker->free_conns = NULL;

    for (int pool_index = 0; pool_index < BUFFER_POOL_DEFAULT_CAPACITY; pool_index++) {
        conn_t *preallocated_conn = calloc(1, sizeof(conn_t));
        if (preallocated_conn) {
            preallocated_conn->fd = -1;
            preallocated_conn->next_free = worker->free_conns;
            worker->free_conns = preallocated_conn;
        }
    }

    struct epoll_event epoll_events[MAX_EVENTS];

    while (g_running) {
        uint64_t current_time_ms = clock_monotonic_ms();

        timer_wheel_process_expired(&worker->timers, worker, current_time_ms);

        int timeout_ms = timer_wheel_next_timeout_ms(&worker->timers, current_time_ms);
        if (timeout_ms < 0 || timeout_ms > 1000) {
            timeout_ms = 1000;
        }

        int num_ready_descriptors = epoll_wait(worker->epoll_fd, epoll_events, MAX_EVENTS, timeout_ms);

        if (num_ready_descriptors < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }

        current_time_ms = clock_monotonic_ms();
        trim_inactive_connections(worker, current_time_ms);

        timer_wheel_process_expired(&worker->timers, worker, current_time_ms);

        for (int event_index = 0; event_index < num_ready_descriptors; event_index++) {
            void *event_data_ptr = epoll_events[event_index].data.ptr;
            uint32_t event_flags = epoll_events[event_index].events;

            if (event_data_ptr == &worker->token_h1) {
                handle_accept_http1(worker);
                continue;
            }

            if (worker->listen_tls_fd >= 0 && event_data_ptr == &worker->token_tls) {
                handle_accept_tls(worker);
                continue;
            }

            if (worker->listen_h2c_fd >= 0 && event_data_ptr == &worker->token_h2c) {
                handle_accept_h2c(worker);
                continue;
            }

            if (worker->listen_h2_fd >= 0 && event_data_ptr == &worker->token_h2) {
                handle_accept_h2(worker);
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

            if (connection->in_stalled_list && (current_time_ms - connection->stalled_since_ms > 5000)) {
                close_conn(worker, connection);
                continue;
            }

            if (connection->read_pos > 0 && connection->request_started_ms > 0 &&
                (current_time_ms - connection->request_started_ms > 5000)) {
                close_conn(worker, connection);
                continue;
            }

            conn_touch(worker, connection, current_time_ms);

            if (connection->is_tls && !connection->tls_handshake_done) {
                int handshake_status = SSL_accept(connection->ssl);
                if (handshake_status <= 0) {
                    int ssl_error = SSL_get_error(connection->ssl, handshake_status);
                    if (ssl_error == SSL_ERROR_WANT_READ) {
                        continue;
                    }
                    if (ssl_error == SSL_ERROR_WANT_WRITE) {
                        struct epoll_event event = {.events = EPOLLOUT | EPOLLRDHUP | EPOLLHUP | EPOLLERR,
                                                    .data.ptr = connection};
                        epoll_ctl(worker->epoll_fd, EPOLL_CTL_MOD, connection->fd, &event);
                        continue;
                    }
                    if (ssl_error == SSL_ERROR_SYSCALL &&
                        (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
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
                        if (connection->fd >= 0) {
                            close_conn(worker, connection);
                        }
                        continue;
                    }
                }

                uint32_t connection_events = EPOLLIN | EPOLLRDHUP | EPOLLHUP | EPOLLERR;
                if (connection->pending_write) {
                    connection_events |= EPOLLOUT;
                }
                struct epoll_event event = {.events = connection_events, .data.ptr = connection};
                epoll_ctl(worker->epoll_fd, EPOLL_CTL_MOD, connection->fd, &event);
            }

            if (event_flags & EPOLLOUT) {
                if (connection->pending_write) {
                    if (!flush_pending_write(worker, connection)) {
                        continue;
                    }
                }
                if (connection->is_h2 && !h2_connection_drain_send(connection, worker)) {
                    if (connection->fd >= 0) {
                        close_conn(worker, connection);
                    }
                    continue;
                }
            }

            bool has_tls_pending = (connection->is_tls && connection->tls_handshake_done &&
                                    (SSL_pending(connection->ssl) > 0 || SSL_has_pending(connection->ssl)));
            if ((event_flags & EPOLLIN) || has_tls_pending) {
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
                                if (ssl_error == SSL_ERROR_SYSCALL &&
                                    (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
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
                            if (connection->fd >= 0) {
                                close_conn(worker, connection);
                            }
                            break;
                        }
                    }
                    if (connection->fd >= 0 && !h2_connection_drain_send(connection, worker)) {
                        if (connection->fd >= 0) {
                            close_conn(worker, connection);
                        }
                    }
                    continue;
                }

                while (true) {
                    if (!connection->read_buf) {
                        connection->read_buf = buffer_pool_acquire(&worker->buffer_pool);
                        if (!connection->read_buf) {
                            close_conn(worker, connection);
                            break;
                        }
                        connection->read_cap = BUFFER_POOL_SLAB_SIZE;
                        connection->has_pooled_buffer = true;
                        connection->read_pos = 0;
                    }

                    if (connection->read_pos == connection->read_cap) {
                        const char *header_end = memmem(connection->read_buf, connection->read_pos, "\r\n\r\n", 4);
                        if (!header_end && connection->read_cap >= 16384) {
                            close_conn(worker, connection);
                            break;
                        }
                        size_t new_capacity = connection->read_cap * 2;
                        if (new_capacity < 65536) {
                            new_capacity = 65536;
                        }
                        if (new_capacity > 256 * 1024) {
                            new_capacity = 256 * 1024;
                        }
                        if (new_capacity > connection->read_cap) {
                            char *new_buffer = malloc(new_capacity);
                            if (!new_buffer) {
                                close_conn(worker, connection);
                                break;
                            }
                            memcpy(new_buffer, connection->read_buf, connection->read_pos);
                            if (connection->has_pooled_buffer) {
                                buffer_pool_release(&worker->buffer_pool, connection->read_buf);
                                connection->has_pooled_buffer = false;
                            } else {
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
                            if (ssl_error == SSL_ERROR_SYSCALL &&
                                (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
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
                    if (bytes_read > 0 && connection->request_started_ms == 0) {
                        connection->request_started_ms = current_time_ms;
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
                    while (connection->fd >= 0 && !connection->closing &&
                           (SSL_pending(connection->ssl) > 0 || SSL_has_pending(connection->ssl))) {
                        if (!connection->read_buf) {
                            connection->read_buf = buffer_pool_acquire(&worker->buffer_pool);
                            if (!connection->read_buf) {
                                close_conn(worker, connection);
                                break;
                            }
                            connection->read_cap = BUFFER_POOL_SLAB_SIZE;
                            connection->has_pooled_buffer = true;
                            connection->read_pos = 0;
                        }
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
    if (worker->listen_h2c_fd >= 0) {
        close(worker->listen_h2c_fd);
    }
    if (worker->listen_h2_fd >= 0) {
        close(worker->listen_h2_fd);
    }
    compress_worker_destroy(&worker->compress);
    timer_wheel_destroy(&worker->timers);
    buffer_pool_destroy(&worker->buffer_pool);

    conn_t *current_connection = worker->free_conns;
    while (current_connection) {
        conn_t *next_connection = current_connection->next_free;
        if (current_connection->read_buf) {
            if (!current_connection->has_pooled_buffer) {
                free(current_connection->read_buf);
            }
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
