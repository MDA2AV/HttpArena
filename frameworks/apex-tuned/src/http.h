#pragma once

#include "common.h"

typedef enum {
    HTTP_METHOD_GET = 0,
    HTTP_METHOD_POST,
    HTTP_METHOD_HEAD,
    HTTP_METHOD_PUT,
    HTTP_METHOD_DELETE,
    HTTP_METHOD_UNKNOWN
} http_method_t;

typedef struct {
    str_view_t name;
    str_view_t val;
} http_header_t;

typedef struct {
    str_view_t key;
    str_view_t val;
} query_param_t;

typedef struct {
    http_method_t method;
    str_view_t    uri;
    str_view_t    path;
    str_view_t    query;
    str_view_t    body;

    http_header_t headers[MAX_HEADERS];
    size_t        num_headers;

    query_param_t params[MAX_PARAMS];
    size_t        num_params;

    str_view_t    route_params[MAX_PARAMS];
    size_t        num_route_params;

    int64_t       content_length;
    bool          is_chunked;
    bool          keep_alive;
    str_view_t    accept_encoding;
    str_view_t    content_type;
} request_t;

typedef struct {
    int           status;
    bool          keep_alive;
    bool          body_needs_free;
    const char   *content_type;
    const char   *content_encoding;
    const char   *extra_headers;
    size_t        extra_headers_len;
    const char   *body;
    size_t        body_len;
} response_t;

void req_init(request_t *req);
void req_parse_query(request_t *req);
str_view_t req_get_header(const request_t *req, const char *name);
bool req_get_query_param(const request_t *req, const char *key, str_view_t *out_val);

void res_init(response_t *res, bool keep_alive);
void res_set_status(response_t *res, int status);
void res_set_text(response_t *res, const char *text, size_t len);
void res_set_json(response_t *res, const char *json, size_t len);
void res_set_binary(response_t *res, const char *data, size_t len, const char *content_type);

size_t res_serialize(const response_t *res, char *out_buf, size_t max_out);

int parse_http_request(const char *buf, size_t len, request_t *req, char *chunk_buf, size_t max_chunk, size_t *consumed_out);
