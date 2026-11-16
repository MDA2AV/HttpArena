#include "response_builder.h"
#include "connection.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>

int64_t calculate_query_integer_sum_fast(const char *query, size_t query_length) {
    if (__builtin_expect(query_length >= 7 && query_length <= 21 && (query_length & 1) != 0, 1)) {
        size_t digit_count = (query_length - 5) >> 1;
        size_t separator_offset = digit_count + 2;
        size_t second_value_offset = digit_count + 5;
        bool has_two_value_layout = query[0] == 'a' && query[1] == '=' && query[separator_offset] == '&' &&
                                    query[separator_offset + 1] == 'b' && query[separator_offset + 2] == '=';
        uint64_t parsed_sum;
        if (__builtin_expect(has_two_value_layout &&
                                 sum_two_ascii_digits_fast(query + 2, query + second_value_offset, digit_count,
                                                           &parsed_sum),
                             1)) {
            return (int64_t)parsed_sum;
        }
    }

    uint64_t accumulated_sum = 0;
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
            uint64_t parsed_number = 0;
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

            accumulated_sum += is_negative ? 0 - parsed_number : parsed_number;
        }

        cursor = ampersand_separator ? ampersand_separator + 1 : query_end;
    }

    return (int64_t)accumulated_sum;
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

    uint64_t parsed_value = 0;
    while (cursor < buffer_end) {
        char digit = *cursor;
        if (digit >= '0' && digit <= '9') {
            parsed_value = (parsed_value * 10) + (digit - '0');
        } else {
            break;
        }
        cursor++;
    }

    return (int64_t)(is_negative ? 0 - parsed_value : parsed_value);
}

bool parse_baseline_request_fast(const char *buffer, size_t buffer_length, size_t *out_consumed_bytes,
                                 int64_t *out_sum) {
    static const char get_baseline11_prefix[] = "GET /baseline11?";
    static const char post_baseline11_prefix[] = "POST /baseline11?";
    static const char get_baseline2_prefix[] = "GET /baseline2?";
    static const char get_query_prefix[] = "GET /query?";
    static const char request_line_suffix[] = " HTTP/1.1\r\n";
    static const char host_prefix[] = "Host: ";
    static const char content_length_prefix[] = "Content-Length: ";
    static const char chunked_header[] = "Transfer-Encoding: chunked\r\n\r\n";

    const char *query_start;
    bool is_post = false;
    if (buffer_length >= sizeof(get_baseline11_prefix) - 1 &&
        memcmp(buffer, get_baseline11_prefix, sizeof(get_baseline11_prefix) - 1) == 0) {
        query_start = buffer + sizeof(get_baseline11_prefix) - 1;
    } else if (buffer_length >= sizeof(post_baseline11_prefix) - 1 &&
               memcmp(buffer, post_baseline11_prefix, sizeof(post_baseline11_prefix) - 1) == 0) {
        query_start = buffer + sizeof(post_baseline11_prefix) - 1;
        is_post = true;
    } else if (buffer_length >= sizeof(get_baseline2_prefix) - 1 &&
               memcmp(buffer, get_baseline2_prefix, sizeof(get_baseline2_prefix) - 1) == 0) {
        query_start = buffer + sizeof(get_baseline2_prefix) - 1;
    } else if (buffer_length >= sizeof(get_query_prefix) - 1 &&
               memcmp(buffer, get_query_prefix, sizeof(get_query_prefix) - 1) == 0) {
        query_start = buffer + sizeof(get_query_prefix) - 1;
    } else {
        return false;
    }

    const char *buffer_end = buffer + buffer_length;
    const char *query_end = memmem(query_start, (size_t)(buffer_end - query_start), request_line_suffix,
                                   sizeof(request_line_suffix) - 1);
    if (!query_end) {
        return false;
    }

    const char *header_cursor = query_end + sizeof(request_line_suffix) - 1;
    if ((size_t)(buffer_end - header_cursor) < sizeof(host_prefix) - 1 ||
        memcmp(header_cursor, host_prefix, sizeof(host_prefix) - 1) != 0) {
        return false;
    }

    const char *host_end = memchr(header_cursor + sizeof(host_prefix) - 1, '\r',
                                  (size_t)(buffer_end - (header_cursor + sizeof(host_prefix) - 1)));
    if (!host_end || (size_t)(buffer_end - host_end) < 2 || host_end[1] != '\n') {
        return false;
    }
    header_cursor = host_end + 2;

    int64_t sum = calculate_query_integer_sum_fast(query_start, (size_t)(query_end - query_start));
    if (!is_post) {
        if ((size_t)(buffer_end - header_cursor) < 2 || header_cursor[0] != '\r' || header_cursor[1] != '\n') {
            return false;
        }
        *out_consumed_bytes = (size_t)(header_cursor + 2 - buffer);
        *out_sum = sum;
        return true;
    }

    if ((size_t)(buffer_end - header_cursor) >= sizeof(content_length_prefix) - 1 &&
        memcmp(header_cursor, content_length_prefix, sizeof(content_length_prefix) - 1) == 0) {
        const char *length_start = header_cursor + sizeof(content_length_prefix) - 1;
        const char *length_end = memchr(length_start, '\r', (size_t)(buffer_end - length_start));
        if (!length_end || (size_t)(buffer_end - length_end) < 4 || length_end[1] != '\n' ||
            length_end[2] != '\r' || length_end[3] != '\n') {
            return false;
        }

        uint64_t body_length;
        if (!parse_ascii_digits_fast(length_start, (size_t)(length_end - length_start), &body_length)) {
            return false;
        }
        const char *body = length_end + 4;
        if (body_length > (uint64_t)(buffer_end - body)) {
            return false;
        }

        *out_consumed_bytes = (size_t)(body - buffer) + (size_t)body_length;
        *out_sum = (int64_t)((uint64_t)sum + (uint64_t)parse_integer_fast(body, (size_t)body_length));
        return true;
    }

    if ((size_t)(buffer_end - header_cursor) >= sizeof(chunked_header) - 1 &&
        memcmp(header_cursor, chunked_header, sizeof(chunked_header) - 1) == 0) {
        const char *chunk = header_cursor + sizeof(chunked_header) - 1;
        static const char single_two_byte_chunk_suffix[] = "\r\n0\r\n\r\n";
        if ((size_t)(buffer_end - chunk) < 12 || chunk[0] != '2' || chunk[1] != '\r' || chunk[2] != '\n' ||
            memcmp(chunk + 5, single_two_byte_chunk_suffix, sizeof(single_two_byte_chunk_suffix) - 1) != 0) {
            return false;
        }

        *out_consumed_bytes = (size_t)(chunk + 12 - buffer);
        *out_sum = (int64_t)((uint64_t)sum + (uint64_t)parse_integer_fast(chunk + 3, 2));
        return true;
    }

    return false;
}

size_t format_plain_text_pipeline_response(char *destination_buffer, bool keep_alive, bool *out_closing) {
    if (__builtin_expect(keep_alive, 1)) {
        static const char response_pipeline_keep_alive[] =
            "HTTP/1.1 200 OK\r\nContent-Type:text/plain\r\nContent-Length:2\r\n\r\nok";
        memcpy(destination_buffer, response_pipeline_keep_alive, sizeof(response_pipeline_keep_alive) - 1);
        return sizeof(response_pipeline_keep_alive) - 1;
    } else {
        static const char response_pipeline_close[] =
            "HTTP/1.1 200 OK\r\nContent-Type:text/plain\r\nConnection:close\r\nContent-Length:2\r\n\r\nok";
        memcpy(destination_buffer, response_pipeline_close, sizeof(response_pipeline_close) - 1);
        if (out_closing) {
            *out_closing = true;
        }
        return sizeof(response_pipeline_close) - 1;
    }
}

static inline size_t format_baseline_response_payload(char *destination_buffer, const char *header,
                                                      size_t header_length, int64_t accumulated_sum) {
    memcpy(destination_buffer, header, header_length);
    char *content_length = destination_buffer + header_length;
    char *body = content_length + 5;
    size_t body_length = format_i64(body, accumulated_sum);

    if (__builtin_expect(body_length < 10, 1)) {
        content_length[0] = (char)('0' + body_length);
        memcpy(content_length + 1, "\r\n\r\n", 4);
        return header_length + 5 + body_length;
    }

    memmove(body + 1, body, body_length);
    memcpy(content_length, decimal_digit_pair((uint32_t)body_length), 2);
    memcpy(content_length + 2, "\r\n\r\n", 4);
    return header_length + 6 + body_length;
}

size_t format_plain_text_baseline_response(char *destination_buffer, int64_t accumulated_sum, bool keep_alive,
                                            bool *out_closing) {
    if (__builtin_expect(keep_alive, 1)) {
        static const char header_keep_alive[] =
            "HTTP/1.1 200 \r\nContent-Type:text/plain\r\nContent-Length:";
        return format_baseline_response_payload(destination_buffer, header_keep_alive,
                                                sizeof(header_keep_alive) - 1, accumulated_sum);
    }

    static const char header_close[] =
        "HTTP/1.1 200 \r\nContent-Type:text/plain\r\nConnection:close\r\nContent-Length:";
    if (out_closing) {
        *out_closing = true;
    }
    return format_baseline_response_payload(destination_buffer, header_close, sizeof(header_close) - 1,
                                            accumulated_sum);
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
