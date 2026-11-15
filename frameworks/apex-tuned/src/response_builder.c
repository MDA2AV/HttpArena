#include "response_builder.h"
#include "connection.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>

int64_t calculate_query_integer_sum_fast(const char *query, size_t query_length) {
    int64_t accumulated_sum = 0;
    const char *cursor = query;
    const char *query_end = query + query_length;

    while (cursor < query_end) {
        const char *equals_separator = memchr(cursor, '=', (size_t)(query_end - cursor));
        if (!equals_separator) {
            break;
        }

        const char *value_start = equals_separator + 1;
        const char *ampersand_separator = memchr(value_start, '&', (size_t)(query_end - value_start));
        const char *value_end = ampersand_separator ? ampersand_separator : query_end;

        if (value_start < value_end) {
            int64_t parsed_number = 0;
            const char *number_cursor = value_start;
            bool is_negative = false;

            if (*number_cursor == '-') {
                is_negative = true;
                number_cursor++;
            }

            while (number_cursor < value_end) {
                char current_digit = *number_cursor;
                if (current_digit >= '0' && current_digit <= '9') {
                    parsed_number = (parsed_number * 10) + (current_digit - '0');
                } else {
                    break;
                }
                number_cursor++;
            }

            accumulated_sum += is_negative ? -parsed_number : parsed_number;
        }

        cursor = ampersand_separator ? ampersand_separator + 1 : query_end;
    }

    return accumulated_sum;
}

int64_t parse_integer_fast(const char *buffer, size_t buffer_length) {
    if (buffer_length == 0 || !buffer) {
        return 0;
    }

    const char *cursor = buffer;
    const char *buffer_end = buffer + buffer_length;
    while (cursor < buffer_end && (*cursor == ' ' || *cursor == '\t' || *cursor == '\r' || *cursor == '\n')) {
        cursor++;
    }

    if (cursor == buffer_end) {
        return 0;
    }

    bool is_negative = false;
    if (*cursor == '-') {
        is_negative = true;
        cursor++;
    }

    int64_t parsed_value = 0;
    while (cursor < buffer_end) {
        char digit = *cursor;
        if (digit >= '0' && digit <= '9') {
            parsed_value = (parsed_value * 10) + (digit - '0');
        } else {
            break;
        }
        cursor++;
    }

    return is_negative ? -parsed_value : parsed_value;
}

size_t format_plain_text_pipeline_response(char *destination_buffer, bool keep_alive, bool *out_closing) {
    if (__builtin_expect(keep_alive, 1)) {
        static const char response_pipeline_keep_alive[] =
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: keep-alive\r\nContent-Length: 2\r\n\r\nok";
        memcpy(destination_buffer, response_pipeline_keep_alive, sizeof(response_pipeline_keep_alive) - 1);
        return sizeof(response_pipeline_keep_alive) - 1;
    } else {
        static const char response_pipeline_close[] =
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: 2\r\n\r\nok";
        memcpy(destination_buffer, response_pipeline_close, sizeof(response_pipeline_close) - 1);
        if (out_closing) {
            *out_closing = true;
        }
        return sizeof(response_pipeline_close) - 1;
    }
}

size_t format_plain_text_baseline_response(char *destination_buffer, int64_t accumulated_sum, bool keep_alive,
                                           bool *out_closing) {
    char number_buffer[32];
    size_t number_length = (size_t)format_i64(number_buffer, accumulated_sum);
    char *cursor = destination_buffer;

    if (__builtin_expect(keep_alive, 1)) {
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
        if (out_closing) {
            *out_closing = true;
        }
    }
    return (size_t)(cursor - destination_buffer);
}

bool flush_pending_write(worker_t *worker, conn_t *connection) {
    if (!connection->pending_write) {
        return true;
    }

    while (connection->pending_write_sent < connection->pending_write_len) {
        const char *write_start = connection->pending_write + connection->pending_write_sent;
        size_t remaining_bytes = connection->pending_write_len - connection->pending_write_sent;

        ssize_t bytes_transferred = 0;
        if (connection->is_tls && connection->ssl) {
            int ssl_result = SSL_write(connection->ssl, write_start, (int)remaining_bytes);
            if (ssl_result <= 0) {
                int ssl_error = SSL_get_error(connection->ssl, ssl_result);
                if (ssl_error == SSL_ERROR_WANT_WRITE || ssl_error == SSL_ERROR_WANT_READ) {
                    return false;
                }
                if (ssl_error == SSL_ERROR_SYSCALL && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
                    return false;
                }
                close_conn(worker, connection);
                return false;
            }
            bytes_transferred = ssl_result;
        } else {
            bytes_transferred = send(connection->fd, write_start, remaining_bytes, MSG_NOSIGNAL);
            if (bytes_transferred < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    return false;
                }
                close_conn(worker, connection);
                return false;
            }
        }

        connection->pending_write_sent += (size_t)bytes_transferred;
        if (connection->in_stalled_list) {
            connection->stalled_since_ms = clock_monotonic_ms();
        }
    }

    free(connection->pending_write);
    connection->pending_write = NULL;
    connection->pending_write_len = 0;
    connection->pending_write_sent = 0;
    conn_unmark_stalled(worker, connection);

    struct epoll_event event_config = {.events = EPOLLIN | EPOLLRDHUP | EPOLLHUP | EPOLLERR,
                                       .data.ptr = connection};
    epoll_ctl(worker->epoll_fd, EPOLL_CTL_MOD, connection->fd, &event_config);

    if (connection->closing) {
        close_conn(worker, connection);
        return false;
    }

    return true;
}

void flush_data(worker_t *worker, conn_t *connection, const char *data, size_t length) {
    if (!length || !data) {
        return;
    }

    if (connection->pending_write) {
        size_t existing_remaining = connection->pending_write_len - connection->pending_write_sent;
        size_t new_total = existing_remaining + length;
        if (__builtin_expect(new_total > 65536, 0)) {
            close_conn(worker, connection);
            return;
        }
        char *reallocated_buffer = malloc(new_total);
        if (!reallocated_buffer) {
            close_conn(worker, connection);
            return;
        }
        memcpy(reallocated_buffer, connection->pending_write + connection->pending_write_sent, existing_remaining);
        memcpy(reallocated_buffer + existing_remaining, data, length);
        free(connection->pending_write);
        connection->pending_write = reallocated_buffer;
        connection->pending_write_len = new_total;
        connection->pending_write_sent = 0;
        return;
    }

    size_t sent_bytes = 0;
    while (sent_bytes < length) {
        ssize_t bytes_transferred = 0;
        if (connection->is_tls && connection->ssl) {
            int ssl_result = SSL_write(connection->ssl, data + sent_bytes, (int)(length - sent_bytes));
            if (ssl_result <= 0) {
                int ssl_error = SSL_get_error(connection->ssl, ssl_result);
                if (ssl_error == SSL_ERROR_WANT_WRITE || ssl_error == SSL_ERROR_WANT_READ) {
                    break;
                }
                if (ssl_error == SSL_ERROR_SYSCALL && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
                    break;
                }
                close_conn(worker, connection);
                return;
            }
            bytes_transferred = ssl_result;
        } else {
            bytes_transferred = send(connection->fd, data + sent_bytes, length - sent_bytes, MSG_NOSIGNAL);
            if (bytes_transferred < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    break;
                }
                close_conn(worker, connection);
                return;
            }
        }
        sent_bytes += (size_t)bytes_transferred;
        if (connection->in_stalled_list) {
            connection->stalled_since_ms = clock_monotonic_ms();
        }
    }

    if (sent_bytes < length) {
        size_t unsent_bytes = length - sent_bytes;
        if (__builtin_expect(unsent_bytes > 65536, 0)) {
            close_conn(worker, connection);
            return;
        }
        connection->pending_write = malloc(unsent_bytes);
        if (!connection->pending_write) {
            close_conn(worker, connection);
            return;
        }
        memcpy(connection->pending_write, data + sent_bytes, unsent_bytes);
        connection->pending_write_len = unsent_bytes;
        connection->pending_write_sent = 0;
        conn_mark_stalled(worker, connection);

        struct epoll_event event_config = {
            .events = EPOLLIN | EPOLLOUT | EPOLLRDHUP | EPOLLHUP | EPOLLERR, .data.ptr = connection};
        epoll_ctl(worker->epoll_fd, EPOLL_CTL_MOD, connection->fd, &event_config);
    } else if (connection->closing) {
        close_conn(worker, connection);
    }
}
