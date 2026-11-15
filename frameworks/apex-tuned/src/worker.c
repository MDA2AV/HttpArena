#include "worker.h"
#include "buffer_pool.h"
#include "common.h"
#include "connection.h"
#include "h2.h"
#include "handlers.h"
#include "listener.h"
#include "response_builder.h"
#include "router.h"
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

        // Ultra-fast path for /pipeline
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

        // Ultra-fast path for /baseline11
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

        // Ultra-fast path for /baseline2
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
        } else {
            connection->read_pos = 0;
        }
    }

    if (write_pos > 0) {
        flush_data(worker, connection, worker->write_buf, write_pos);
    }

    // Release pooled buffer back to thread-local pool if connection is idle
    if (connection->read_pos == 0 && connection->read_buf) {
        if (connection->has_pooled_buffer) {
            buffer_pool_release(&worker->buffer_pool, connection->read_buf);
        } else {
            free(connection->read_buf);
        }
        connection->read_buf = NULL;
        connection->read_cap = 0;
        connection->has_pooled_buffer = false;
    }
}

void *worker_thread_main(void *thread_argument) {
    worker_t *worker = (worker_t *)thread_argument;
    t_worker = worker;

#if defined(__linux__) && defined(PR_SET_TIMERSLACK)
    prctl(PR_SET_TIMERSLACK, 1UL, 0, 0, 0);
#endif

    cpu_set_t cpu_set;
    CPU_ZERO(&cpu_set);
    CPU_SET(worker->cpu_id, &cpu_set);
    pthread_setaffinity_np(pthread_self(), sizeof(cpu_set), &cpu_set);

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

#if defined(__linux__)
        if (worker->id == 0 && (current_time_ms - worker->last_trim_ms >= 5000)) {
            worker->last_trim_ms = current_time_ms;
            malloc_trim(0);
        }
#endif

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
                        close_conn(worker, connection);
                        continue;
                    }
                }

                struct epoll_event event = {.events = EPOLLIN | EPOLLRDHUP | EPOLLHUP | EPOLLERR,
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
                            close_conn(worker, connection);
                            break;
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
