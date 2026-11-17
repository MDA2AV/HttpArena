#include "http.h"
#include <ctype.h>

void req_init(request_t *request) {
    request->method = HTTP_METHOD_UNKNOWN;
    request->uri = (str_view_t){NULL, 0};
    request->path = (str_view_t){NULL, 0};
    request->query = (str_view_t){NULL, 0};
    request->body = (str_view_t){NULL, 0};
    request->num_headers = 0;
    request->num_params = 0;
    request->num_route_params = 0;
    request->content_length = -1;
    request->is_chunked = false;
    request->keep_alive = true;
    request->is_http11 = false;
    request->accept_encoding = (str_view_t){NULL, 0};
    request->content_type = (str_view_t){NULL, 0};
}

void req_parse_query(request_t *request) {
    if (!request->query.len || !request->query.ptr) {
        return;
    }
    const char *cursor = request->query.ptr;
    const char *query_end = cursor + request->query.len;

    while (cursor < query_end && request->num_params < MAX_PARAMS) {
        const char *key_start = cursor;
        const char *equals_separator = NULL;
        while (cursor < query_end && *cursor != '&') {
            if (*cursor == '=' && !equals_separator) {
                equals_separator = cursor;
            }
            cursor++;
        }

        if (equals_separator) {
            request->params[request->num_params].key = (str_view_t){key_start, (size_t)(equals_separator - key_start)};
            request->params[request->num_params].val =
                (str_view_t){equals_separator + 1, (size_t)(cursor - (equals_separator + 1))};
        } else {
            request->params[request->num_params].key = (str_view_t){key_start, (size_t)(cursor - key_start)};
            request->params[request->num_params].val = (str_view_t){NULL, 0};
        }
        request->num_params++;

        if (cursor < query_end && *cursor == '&') {
            cursor++;
        }
    }
}

str_view_t req_get_header(const request_t *request, const char *header_name) {
    for (size_t header_index = 0; header_index < request->num_headers; header_index++) {
        if (view_case_eq(request->headers[header_index].name, header_name)) {
            return request->headers[header_index].val;
        }
    }
    return (str_view_t){NULL, 0};
}

bool req_get_query_param(const request_t *request, const char *parameter_key, str_view_t *out_parameter_value) {
    for (size_t param_index = 0; param_index < request->num_params; param_index++) {
        if (view_eq(request->params[param_index].key, parameter_key)) {
            *out_parameter_value = request->params[param_index].val;
            return true;
        }
    }
    return false;
}

void res_init(response_t *response, bool keep_alive) {
    response->status = 200;
    response->keep_alive = keep_alive;
    response->body_needs_free = false;
    response->content_type = "text/plain";
    response->content_encoding = NULL;
    response->extra_headers = NULL;
    response->extra_headers_len = 0;
    response->body = NULL;
    response->body_len = 0;
}

void res_set_status(response_t *response, int status_code) {
    response->status = status_code;
}

void res_set_text(response_t *response, const char *text, size_t length) {
    response->content_type = "text/plain";
    response->body = text;
    response->body_len = length;
}

void res_set_json(response_t *response, const char *json_string, size_t length) {
    response->content_type = "application/json";
    response->body = json_string;
    response->body_len = length;
}

void res_set_binary(response_t *response, const char *data, size_t length, const char *content_type) {
    response->content_type = content_type ? content_type : "application/octet-stream";
    response->body = data;
    response->body_len = length;
}

static inline const char *status_text(int status_code) {
    switch (status_code) {
    case 200:
        return "200 OK";
    case 204:
        return "204 No Content";
    case 400:
        return "400 Bad Request";
    case 404:
        return "404 Not Found";
    case 405:
        return "405 Method Not Allowed";
    case 500:
        return "500 Internal Server Error";
    case 503:
        return "503 Service Unavailable";
    default:
        return "200 OK";
    }
}

size_t res_serialize(const response_t *response, char *destination_buffer, size_t max_destination_size) {
    char *cursor = destination_buffer;
    char *buffer_end = destination_buffer + max_destination_size;

    if (__builtin_expect(response->status == 200 && response->content_type && !response->content_encoding &&
                             !response->extra_headers && response->keep_alive,
                         1)) {
        if (strcmp(response->content_type, "text/plain") == 0) {
            memcpy(cursor, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ", 59);
            cursor += 59;
            cursor += format_i64(cursor, (int64_t)response->body_len);
            memcpy(cursor, "\r\nConnection: keep-alive\r\n\r\n", 28);
            cursor += 28;
            if (response->body && response->body_len) {
                if ((size_t)(buffer_end - cursor) < response->body_len) {
                    return 0;
                }
                memcpy(cursor, response->body, response->body_len);
                cursor += response->body_len;
            }
            return (size_t)(cursor - destination_buffer);
        } else if (strcmp(response->content_type, "application/json") == 0) {
            memcpy(cursor, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ", 65);
            cursor += 65;
            cursor += format_i64(cursor, (int64_t)response->body_len);
            memcpy(cursor, "\r\nConnection: keep-alive\r\n\r\n", 28);
            cursor += 28;
            if (response->body && response->body_len) {
                if ((size_t)(buffer_end - cursor) < response->body_len) {
                    return 0;
                }
                memcpy(cursor, response->body, response->body_len);
                cursor += response->body_len;
            }
            return (size_t)(cursor - destination_buffer);
        }
    }

    if (__builtin_expect(response->status == 200, 1)) {
        memcpy(cursor, "HTTP/1.1 200 OK\r\n", 17);
        cursor += 17;
    } else {
        const char *status_string = status_text(response->status);
        size_t status_string_length = strlen(status_string);
        memcpy(cursor, "HTTP/1.1 ", 9);
        cursor += 9;
        memcpy(cursor, status_string, status_string_length);
        cursor += status_string_length;
        memcpy(cursor, "\r\n", 2);
        cursor += 2;
    }

    if (response->content_type) {
        if (strcmp(response->content_type, "text/plain") == 0) {
            memcpy(cursor, "Content-Type: text/plain\r\n", 26);
            cursor += 26;
        } else if (strcmp(response->content_type, "application/json") == 0) {
            memcpy(cursor, "Content-Type: application/json\r\n", 32);
            cursor += 32;
        } else {
            size_t content_type_length = strlen(response->content_type);
            memcpy(cursor, "Content-Type: ", 14);
            cursor += 14;
            memcpy(cursor, response->content_type, content_type_length);
            cursor += content_type_length;
            memcpy(cursor, "\r\n", 2);
            cursor += 2;
        }
    }

    if (response->content_encoding) {
        size_t content_encoding_length = strlen(response->content_encoding);
        memcpy(cursor, "Content-Encoding: ", 18);
        cursor += 18;
        memcpy(cursor, response->content_encoding, content_encoding_length);
        cursor += content_encoding_length;
        memcpy(cursor, "\r\n", 2);
        cursor += 2;
    }

    memcpy(cursor, "Content-Length: ", 16);
    cursor += 16;
    cursor += format_i64(cursor, (int64_t)response->body_len);
    memcpy(cursor, "\r\n", 2);
    cursor += 2;

    if (response->keep_alive) {
        memcpy(cursor, "Connection: keep-alive\r\n", 24);
        cursor += 24;
    } else {
        memcpy(cursor, "Connection: close\r\n", 19);
        cursor += 19;
    }

    if (response->extra_headers && response->extra_headers_len) {
        memcpy(cursor, response->extra_headers, response->extra_headers_len);
        cursor += response->extra_headers_len;
    }

    memcpy(cursor, "\r\n", 2);
    cursor += 2;

    if (response->body && response->body_len) {
        if ((size_t)(buffer_end - cursor) < response->body_len) {
            return 0;
        }
        memcpy(cursor, response->body, response->body_len);
        cursor += response->body_len;
    }

    return (size_t)(cursor - destination_buffer);
}

static inline const char *find_crlf_crlf(const char *buffer, size_t buffer_length, size_t *out_header_length) {
    if (buffer_length < 4) {
        return NULL;
    }
    const char *cursor = buffer;
    const char *search_end = buffer + buffer_length - 3;
    while (cursor < search_end) {
        cursor = memchr(cursor, '\r', (size_t)(search_end - cursor));
        if (!cursor) {
            return NULL;
        }
        if (cursor[1] == '\n' && cursor[2] == '\r' && cursor[3] == '\n') {
            *out_header_length = (size_t)(cursor - buffer) + 4;
            return cursor + 4;
        }
        cursor++;
    }
    return NULL;
}

int parse_http_request(const char *buffer, size_t buffer_length, request_t *request, char *chunk_buffer,
                       size_t max_chunk_size, size_t *out_consumed_bytes) {
    size_t header_length = 0;
    const char *body_start = find_crlf_crlf(buffer, buffer_length, &header_length);
    if (!body_start) {
        return 0;
    }

    req_init(request);

    const char *line_start = buffer;
    const char *line_end = memchr(line_start, '\r', header_length);
    if (!line_end || line_end + 1 >= buffer + header_length || line_end[1] != '\n') {
        return -1;
    }

    const char *space_first = memchr(line_start, ' ', (size_t)(line_end - line_start));
    if (!space_first) {
        return -1;
    }
    size_t method_length = (size_t)(space_first - line_start);
    if (method_length == 3 && memcmp(line_start, "GET", 3) == 0) {
        request->method = HTTP_METHOD_GET;
    } else if (method_length == 4 && memcmp(line_start, "POST", 4) == 0) {
        request->method = HTTP_METHOD_POST;
    } else if (method_length == 4 && memcmp(line_start, "HEAD", 4) == 0) {
        request->method = HTTP_METHOD_HEAD;
    } else if (method_length == 3 && memcmp(line_start, "PUT", 3) == 0) {
        request->method = HTTP_METHOD_PUT;
    } else if (method_length == 6 && memcmp(line_start, "DELETE", 6) == 0) {
        request->method = HTTP_METHOD_DELETE;
    } else {
        request->method = HTTP_METHOD_UNKNOWN;
    }

    const char *space_second = memchr(space_first + 1, ' ', (size_t)(line_end - (space_first + 1)));
    if (!space_second) {
        return -1;
    }

    request->uri = (str_view_t){space_first + 1, (size_t)(space_second - (space_first + 1))};
    const char *question_mark = memchr(request->uri.ptr, '?', request->uri.len);
    if (question_mark) {
        request->path = (str_view_t){request->uri.ptr, (size_t)(question_mark - request->uri.ptr)};
        request->query =
            (str_view_t){question_mark + 1, (size_t)(request->uri.ptr + request->uri.len - (question_mark + 1))};
    } else {
        request->path = request->uri;
        request->query = (str_view_t){NULL, 0};
    }

    str_view_t protocol_view = (str_view_t){space_second + 1, (size_t)(line_end - (space_second + 1))};
    request->is_http11 = view_eq(protocol_view, "HTTP/1.1");
    if (!request->is_http11 && view_eq(protocol_view, "HTTP/1.0")) {
        request->keep_alive = false;
    }

    const char *header_cursor = line_end + 2;
    const char *headers_end = buffer + header_length - 2;

    while (header_cursor < headers_end && request->num_headers < MAX_HEADERS) {
        const char *next_line = memmem(header_cursor, (size_t)(headers_end - header_cursor), "\r\n", 2);
        if (!next_line) {
            break;
        }
        if (next_line == header_cursor) {
            header_cursor += 2;
            break;
        }

        const char *colon = memchr(header_cursor, ':', (size_t)(next_line - header_cursor));
        if (colon) {
            const char *header_name = header_cursor;
            size_t header_name_length = (size_t)(colon - header_cursor);
            const char *header_value = colon + 1;
            while (header_value < next_line && (*header_value == ' ' || *header_value == '\t')) {
                header_value++;
            }
            const char *header_value_end = next_line;
            while (header_value_end > header_value &&
                   (*(header_value_end - 1) == ' ' || *(header_value_end - 1) == '\t')) {
                header_value_end--;
            }

            request->headers[request->num_headers].name = (str_view_t){header_name, header_name_length};
            request->headers[request->num_headers].val =
                (str_view_t){header_value, (size_t)(header_value_end - header_value)};

            str_view_t header_value_view = request->headers[request->num_headers].val;

            char first_char_lower = (char)(header_name[0] | 0x20);
            if (first_char_lower == 'c') {
                if (header_name_length == 14 && strncasecmp(header_name, "content-length", 14) == 0) {
                    int64_t content_length_val = 0;
                    if (parse_i64(header_value_view.ptr, header_value_view.len, &content_length_val) &&
                        content_length_val >= 0) {
                        request->content_length = content_length_val;
                    }
                } else if (header_name_length == 10 && strncasecmp(header_name, "connection", 10) == 0) {
                    if (view_case_eq(header_value_view, "close")) {
                        request->keep_alive = false;
                    } else if (view_case_eq(header_value_view, "keep-alive")) {
                        request->keep_alive = true;
                    }
                } else if (header_name_length == 12 && strncasecmp(header_name, "content-type", 12) == 0) {
                    request->content_type = header_value_view;
                }
            } else if (first_char_lower == 't') {
                if (header_name_length == 17 && strncasecmp(header_name, "transfer-encoding", 17) == 0) {
                    if (view_case_eq(header_value_view, "chunked") || strcasestr(header_value_view.ptr, "chunked")) {
                        request->is_chunked = true;
                    }
                }
            } else if (first_char_lower == 'a') {
                if (header_name_length == 15 && strncasecmp(header_name, "accept-encoding", 15) == 0) {
                    request->accept_encoding = header_value_view;
                }
            }

            request->num_headers++;
        }
        header_cursor = next_line + 2;
    }

    if (request->is_chunked) {
        const char *current_chunk = body_start;
        const char *buffer_end_ptr = buffer + buffer_length;
        size_t total_decoded_bytes = 0;

        while (true) {
            const char *chunk_header_end = memmem(current_chunk, (size_t)(buffer_end_ptr - current_chunk), "\r\n", 2);
            if (!chunk_header_end) {
                return 0;
            }

            char *parse_end_ptr = NULL;
            unsigned long chunk_size = strtoul(current_chunk, &parse_end_ptr, 16);
            if (parse_end_ptr == current_chunk) {
                return -1;
            }

            const char *chunk_payload = chunk_header_end + 2;
            if (chunk_size == 0) {
                const char *trailing_crlf = memmem(chunk_payload, (size_t)(buffer_end_ptr - chunk_payload), "\r\n", 2);
                if (!trailing_crlf) {
                    return 0;
                }
                current_chunk = trailing_crlf + 2;
                break;
            }

            if ((size_t)(buffer_end_ptr - chunk_payload) < chunk_size + 2) {
                return 0;
            }
            if (chunk_payload[chunk_size] != '\r' || chunk_payload[chunk_size + 1] != '\n') {
                return -1;
            }

            if (total_decoded_bytes + chunk_size > max_chunk_size) {
                return -1;
            }
            memcpy(chunk_buffer + total_decoded_bytes, chunk_payload, chunk_size);
            total_decoded_bytes += chunk_size;

            current_chunk = chunk_payload + chunk_size + 2;
        }

        request->body = (str_view_t){chunk_buffer, total_decoded_bytes};
        *out_consumed_bytes = (size_t)(current_chunk - buffer);
        return 1;
    }

    if (request->content_length > 0) {
        size_t content_length_bytes = (size_t)request->content_length;
        if (buffer_length < header_length + content_length_bytes) {
            return 0;
        }
        request->body = (str_view_t){body_start, content_length_bytes};
        *out_consumed_bytes = header_length + content_length_bytes;
        return 1;
    }

    request->body = (str_view_t){NULL, 0};
    *out_consumed_bytes = header_length;
    return 1;
}
