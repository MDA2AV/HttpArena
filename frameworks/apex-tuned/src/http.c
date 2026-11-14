#include "http.h"
#include <ctype.h>

void req_init(request_t *req) {
    req->method = HTTP_METHOD_UNKNOWN;
    req->uri = (str_view_t){ NULL, 0 };
    req->path = (str_view_t){ NULL, 0 };
    req->query = (str_view_t){ NULL, 0 };
    req->body = (str_view_t){ NULL, 0 };
    req->num_headers = 0;
    req->num_params = 0;
    req->num_route_params = 0;
    req->content_length = -1;
    req->is_chunked = false;
    req->keep_alive = true;
    req->accept_encoding = (str_view_t){ NULL, 0 };
    req->content_type = (str_view_t){ NULL, 0 };
}

void req_parse_query(request_t *req) {
    if (!req->query.len || !req->query.ptr) return;
    const char *p = req->query.ptr;
    const char *end = p + req->query.len;

    while (p < end && req->num_params < MAX_PARAMS) {
        const char *eq = memchr(p, '=', end - p);
        const char *amp = memchr(p, '&', end - p);
        if (!amp) amp = end;

        if (eq && eq < amp) {
            req->params[req->num_params].key = (str_view_t){ p, (size_t)(eq - p) };
            req->params[req->num_params].val = (str_view_t){ eq + 1, (size_t)(amp - (eq + 1)) };
            req->num_params++;
        } else {
            req->params[req->num_params].key = (str_view_t){ p, (size_t)(amp - p) };
            req->params[req->num_params].val = (str_view_t){ NULL, 0 };
            req->num_params++;
        }

        p = (amp < end) ? amp + 1 : end;
    }
}

str_view_t req_get_header(const request_t *req, const char *name) {
    for (size_t i = 0; i < req->num_headers; i++) {
        if (view_case_eq(req->headers[i].name, name)) {
            return req->headers[i].val;
        }
    }
    return (str_view_t){ NULL, 0 };
}

bool req_get_query_param(const request_t *req, const char *key, str_view_t *out_val) {
    for (size_t i = 0; i < req->num_params; i++) {
        if (view_eq(req->params[i].key, key)) {
            *out_val = req->params[i].val;
            return true;
        }
    }
    return false;
}

void res_init(response_t *res, bool keep_alive) {
    res->status = 200;
    res->keep_alive = keep_alive;
    res->body_needs_free = false;
    res->content_type = "text/plain";
    res->content_encoding = NULL;
    res->extra_headers = NULL;
    res->extra_headers_len = 0;
    res->body = NULL;
    res->body_len = 0;
}

void res_set_status(response_t *res, int status) {
    res->status = status;
}

void res_set_text(response_t *res, const char *text, size_t len) {
    res->content_type = "text/plain";
    res->body = text;
    res->body_len = len;
}

void res_set_json(response_t *res, const char *json, size_t len) {
    res->content_type = "application/json";
    res->body = json;
    res->body_len = len;
}

void res_set_binary(response_t *res, const char *data, size_t len, const char *content_type) {
    res->content_type = content_type ? content_type : "application/octet-stream";
    res->body = data;
    res->body_len = len;
}

static inline const char* status_text(int code) {
    switch (code) {
        case 200: return "200 OK";
        case 204: return "204 No Content";
        case 400: return "400 Bad Request";
        case 404: return "404 Not Found";
        case 405: return "405 Method Not Allowed";
        case 500: return "500 Internal Server Error";
        case 503: return "503 Service Unavailable";
        default:  return "200 OK";
    }
}

size_t res_serialize(const response_t *res, char *out_buf, size_t max_out) {
    char *p = out_buf;
    char *end = out_buf + max_out;

    if (__builtin_expect(res->status == 200, 1)) {
        memcpy(p, "HTTP/1.1 200 OK\r\n", 17);
        p += 17;
    } else {
        const char *st = status_text(res->status);
        size_t st_len = strlen(st);
        memcpy(p, "HTTP/1.1 ", 9); p += 9;
        memcpy(p, st, st_len); p += st_len;
        memcpy(p, "\r\n", 2); p += 2;
    }

    if (res->content_type) {
        if (strcmp(res->content_type, "text/plain") == 0) {
            memcpy(p, "Content-Type: text/plain\r\n", 26);
            p += 26;
        } else if (strcmp(res->content_type, "application/json") == 0) {
            memcpy(p, "Content-Type: application/json\r\n", 32);
            p += 32;
        } else {
            size_t ct_len = strlen(res->content_type);
            memcpy(p, "Content-Type: ", 14); p += 14;
            memcpy(p, res->content_type, ct_len); p += ct_len;
            memcpy(p, "\r\n", 2); p += 2;
        }
    }

    if (res->content_encoding) {
        size_t ce_len = strlen(res->content_encoding);
        memcpy(p, "Content-Encoding: ", 18); p += 18;
        memcpy(p, res->content_encoding, ce_len); p += ce_len;
        memcpy(p, "\r\n", 2); p += 2;
    }

    memcpy(p, "Content-Length: ", 16); p += 16;
    p += format_i64(p, (int64_t)res->body_len);
    memcpy(p, "\r\n", 2); p += 2;

    if (res->keep_alive) {
        memcpy(p, "Connection: keep-alive\r\n", 24); p += 24;
    } else {
        memcpy(p, "Connection: close\r\n", 19); p += 19;
    }

    if (res->extra_headers && res->extra_headers_len) {
        memcpy(p, res->extra_headers, res->extra_headers_len);
        p += res->extra_headers_len;
    }

    memcpy(p, "\r\n", 2); p += 2;

    if (res->body && res->body_len) {
        if ((size_t)(end - p) < res->body_len) {
            return 0;
        }
        memcpy(p, res->body, res->body_len);
        p += res->body_len;
    }

    return (size_t)(p - out_buf);
}

static inline const char* find_crlf_crlf(const char *buf, size_t len, size_t *header_len_out) {
    if (len < 4) return NULL;
    const char *found = memmem(buf, len, "\r\n\r\n", 4);
    if (!found) return NULL;
    *header_len_out = (size_t)(found - buf) + 4;
    return found + 4;
}

int parse_http_request(const char *buf, size_t len, request_t *req, char *chunk_buf, size_t max_chunk, size_t *consumed_out) {
    size_t header_len = 0;
    const char *body_start = find_crlf_crlf(buf, len, &header_len);
    if (!body_start) {
        return 0;
    }

    req_init(req);

    const char *line = buf;
    const char *line_end = memmem(line, header_len, "\r\n", 2);
    if (!line_end) return -1;

    const char *sp1 = memchr(line, ' ', line_end - line);
    if (!sp1) return -1;
    size_t mlen = sp1 - line;
    if (mlen == 3 && memcmp(line, "GET", 3) == 0) req->method = HTTP_METHOD_GET;
    else if (mlen == 4 && memcmp(line, "POST", 4) == 0) req->method = HTTP_METHOD_POST;
    else if (mlen == 4 && memcmp(line, "HEAD", 4) == 0) req->method = HTTP_METHOD_HEAD;
    else if (mlen == 3 && memcmp(line, "PUT", 3) == 0) req->method = HTTP_METHOD_PUT;
    else if (mlen == 6 && memcmp(line, "DELETE", 6) == 0) req->method = HTTP_METHOD_DELETE;
    else req->method = HTTP_METHOD_UNKNOWN;

    const char *sp2 = memchr(sp1 + 1, ' ', line_end - (sp1 + 1));
    if (!sp2) return -1;

    req->uri = (str_view_t){ sp1 + 1, (size_t)(sp2 - (sp1 + 1)) };
    const char *qmark = memchr(req->uri.ptr, '?', req->uri.len);
    if (qmark) {
        req->path = (str_view_t){ req->uri.ptr, (size_t)(qmark - req->uri.ptr) };
        req->query = (str_view_t){ qmark + 1, (size_t)(req->uri.ptr + req->uri.len - (qmark + 1)) };
    } else {
        req->path = req->uri;
        req->query = (str_view_t){ NULL, 0 };
    }

    str_view_t proto = (str_view_t){ sp2 + 1, (size_t)(line_end - (sp2 + 1)) };
    if (view_eq(proto, "HTTP/1.0")) {
        req->keep_alive = false;
    } else {
        req->keep_alive = true;
    }

    const char *p = line_end + 2;
    const char *headers_end = buf + header_len - 2;

    while (p < headers_end && req->num_headers < MAX_HEADERS) {
        const char *next_line = memmem(p, headers_end - p, "\r\n", 2);
        if (!next_line) break;
        if (next_line == p) {
            p += 2;
            break;
        }

        const char *colon = memchr(p, ':', next_line - p);
        if (colon) {
            const char *hname = p;
            size_t hname_len = colon - p;
            const char *hval = colon + 1;
            while (hval < next_line && (*hval == ' ' || *hval == '\t')) hval++;
            const char *hval_end = next_line;
            while (hval_end > hval && (*(hval_end - 1) == ' ' || *(hval_end - 1) == '\t')) hval_end--;

            req->headers[req->num_headers].name = (str_view_t){ hname, hname_len };
            req->headers[req->num_headers].val = (str_view_t){ hval, (size_t)(hval_end - hval) };

            str_view_t vval = req->headers[req->num_headers].val;

            char first = (char)(hname[0] | 0x20);
            if (first == 'c') {
                if (hname_len == 14 && strncasecmp(hname, "content-length", 14) == 0) {
                    int64_t cl = 0;
                    if (parse_i64(vval.ptr, vval.len, &cl) && cl >= 0) {
                        req->content_length = cl;
                    }
                } else if (hname_len == 10 && strncasecmp(hname, "connection", 10) == 0) {
                    if (view_case_eq(vval, "close")) {
                        req->keep_alive = false;
                    } else if (view_case_eq(vval, "keep-alive")) {
                        req->keep_alive = true;
                    }
                } else if (hname_len == 12 && strncasecmp(hname, "content-type", 12) == 0) {
                    req->content_type = vval;
                }
            } else if (first == 't') {
                if (hname_len == 17 && strncasecmp(hname, "transfer-encoding", 17) == 0) {
                    if (view_case_eq(vval, "chunked") || strcasestr(vval.ptr, "chunked")) {
                        req->is_chunked = true;
                    }
                }
            } else if (first == 'a') {
                if (hname_len == 15 && strncasecmp(hname, "accept-encoding", 15) == 0) {
                    req->accept_encoding = vval;
                }
            }

            req->num_headers++;
        }
        p = next_line + 2;
    }

    if (req->is_chunked) {
        const char *cur = body_start;
        const char *buf_end = buf + len;
        size_t total_decoded = 0;

        while (true) {
            const char *line_crlf = memmem(cur, buf_end - cur, "\r\n", 2);
            if (!line_crlf) return 0;

            char *endptr = NULL;
            unsigned long chunk_sz = strtoul(cur, &endptr, 16);
            if (endptr == cur) return -1;

            const char *chunk_data = line_crlf + 2;
            if (chunk_sz == 0) {
                const char *trail = memmem(chunk_data, buf_end - chunk_data, "\r\n", 2);
                if (!trail) return 0;
                cur = trail + 2;
                break;
            }

            if ((size_t)(buf_end - chunk_data) < chunk_sz + 2) {
                return 0;
            }
            if (chunk_data[chunk_sz] != '\r' || chunk_data[chunk_sz + 1] != '\n') {
                return -1;
            }

            if (total_decoded + chunk_sz > max_chunk) return -1;
            memcpy(chunk_buf + total_decoded, chunk_data, chunk_sz);
            total_decoded += chunk_sz;

            cur = chunk_data + chunk_sz + 2;
        }

        req->body = (str_view_t){ chunk_buf, total_decoded };
        *consumed_out = (size_t)(cur - buf);
        return 1;
    }

    if (req->content_length > 0) {
        size_t cl = (size_t)req->content_length;
        if (len < header_len + cl) {
            return 0;
        }
        req->body = (str_view_t){ body_start, cl };
        *consumed_out = header_len + cl;
        return 1;
    }

    req->body = (str_view_t){ NULL, 0 };
    *consumed_out = header_len;
    return 1;
}
