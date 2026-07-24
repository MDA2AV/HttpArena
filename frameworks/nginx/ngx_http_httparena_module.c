#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>

/* Static files (/static/<name>) are not handled here — the nginx.conf
 * location /static/ block serves them directly from /data/static via
 * nginx core's sendfile-backed file handler, which is both faster and
 * exercises the "real nginx static path" the benchmark is meant to
 * measure. Any request that reaches this module has already missed
 * that more-specific location. */

/* ---------- Integer parser ---------- */

static int64_t
parse_int(u_char *start, u_char *end)
{
    int64_t n = 0;
    int neg = 0;
    u_char *p = start;
    while (p < end && (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')) p++;
    if (p < end && *p == '-') { neg = 1; p++; }
    while (p < end && *p >= '0' && *p <= '9') {
        n = n * 10 + (*p - '0');
        p++;
    }
    return neg ? -n : n;
}

/* ---------- Query string sum ---------- */

static int64_t
sum_args(ngx_str_t *args)
{
    if (!args->len) return 0;
    int64_t sum = 0;
    u_char *p = args->data, *end = p + args->len;
    while (p < end) {
        u_char *eq = ngx_strlchr(p, end, '=');
        if (!eq) break;
        u_char *v = eq + 1;
        u_char *amp = ngx_strlchr(v, end, '&');
        if (!amp) amp = end;
        sum += parse_int(v, amp);
        p = (amp < end) ? amp + 1 : end;
    }
    return sum;
}

/* ---------- Response helper ---------- */

static ngx_int_t
send_resp(ngx_http_request_t *r, ngx_uint_t status,
          u_char *ct, size_t ct_len,
          u_char *body, size_t body_len, ngx_int_t copy)
{
    ngx_buf_t *b;
    ngx_chain_t out;

    r->headers_out.status = status;
    r->headers_out.content_type.data = ct;
    r->headers_out.content_type.len = ct_len;
    r->headers_out.content_type_len = ct_len;
    r->headers_out.content_length_n = body_len;

    if (r->method == NGX_HTTP_HEAD) {
        return ngx_http_send_header(r);
    }

    if (copy) {
        b = ngx_create_temp_buf(r->pool, body_len);
        if (!b) return NGX_HTTP_INTERNAL_SERVER_ERROR;
        b->last = ngx_copy(b->last, body, body_len);
    } else {
        b = ngx_calloc_buf(r->pool);
        if (!b) return NGX_HTTP_INTERNAL_SERVER_ERROR;
        b->pos = body;
        b->last = body + body_len;
        b->memory = 1;
    }
    b->last_buf = 1;

    out.buf = b;
    out.next = NULL;

    ngx_int_t rc = ngx_http_send_header(r);
    if (rc == NGX_ERROR || rc > NGX_OK || r->header_only) return rc;
    return ngx_http_output_filter(r, &out);
}

/* ---------- POST body handler for /baseline11 ---------- */

static void
baseline11_post_handler(ngx_http_request_t *r)
{
    int64_t sum = sum_args(&r->args);

    /* The canonical nginx idiom for reading a buffered request body is to
     * walk r->request_body->bufs. One chain node per recv(); reading only
     * bufs->buf gives you just the first chunk, which silently breaks on
     * fragmented bodies (validate.sh splits "20" as "2"+"0").
     *
     * request_body_in_single_buf=1 only sizes rb->buf's allocation; it does
     * not produce a merged view. rb->buf->pos is advanced to last by the
     * body-length filter as it hands data off to the save filter, so
     * reading rb->buf directly returns an empty range. Walk the chain. */
    if (r->request_body && r->request_body->bufs) {
        u_char body[64];
        size_t body_len = 0;
        ngx_chain_t *cl;
        for (cl = r->request_body->bufs; cl; cl = cl->next) {
            ngx_buf_t *buf = cl->buf;
            if (!buf || buf->in_file) continue;
            size_t chunk_len = buf->last - buf->pos;
            if (chunk_len == 0) continue;
            if (body_len + chunk_len > sizeof(body)) {
                chunk_len = sizeof(body) - body_len;
            }
            ngx_memcpy(body + body_len, buf->pos, chunk_len);
            body_len += chunk_len;
            if (body_len >= sizeof(body)) break;
        }
        if (body_len > 0) {
            sum += parse_int(body, body + body_len);
        }
    }

    u_char resp[32];
    u_char *last = ngx_snprintf(resp, sizeof(resp), "%L", sum);

    ngx_int_t rc = send_resp(r, 200,
                              (u_char *)"text/plain", 10,
                              resp, last - resp, 1);
    ngx_http_finalize_request(r, rc);
}

/* ---------- Main request handler ---------- */

static ngx_int_t
ngx_http_httparena_handler(ngx_http_request_t *r)
{
    u_char *uri = r->uri.data;
    size_t uri_len = r->uri.len;

    /* Reject unknown HTTP methods — only allow GET, HEAD, POST */
    if (!(r->method & (NGX_HTTP_GET | NGX_HTTP_POST | NGX_HTTP_HEAD))) {
        ngx_http_discard_request_body(r);
        return send_resp(r, 405,
                         (u_char *)"text/plain", 10,
                         (u_char *)"Method Not Allowed", 18, 1);
    }

    /* /pipeline */
    if (uri_len == 9 && ngx_strncmp(uri, "/pipeline", 9) == 0) {
        ngx_http_discard_request_body(r);
        return send_resp(r, 200,
                         (u_char *)"text/plain", 10,
                         (u_char *)"ok", 2, 0);
    }

    /* /baseline2 */
    if (uri_len == 10 && ngx_strncmp(uri, "/baseline2", 10) == 0) {
        ngx_http_discard_request_body(r);
        int64_t sum = sum_args(&r->args);
        u_char buf[32];
        u_char *last = ngx_snprintf(buf, sizeof(buf), "%L", sum);
        return send_resp(r, 200,
                         (u_char *)"text/plain", 10,
                         buf, last - buf, 1);
    }

    /* /baseline11 */
    if (uri_len == 11 && ngx_strncmp(uri, "/baseline11", 11) == 0) {
        if (r->method == NGX_HTTP_POST) {
            r->request_body_in_single_buf = 1;
            ngx_int_t rc = ngx_http_read_client_request_body(r,
                                                              baseline11_post_handler);
            if (rc >= NGX_HTTP_SPECIAL_RESPONSE) return rc;
            return NGX_DONE;
        }
        ngx_http_discard_request_body(r);
        int64_t sum = sum_args(&r->args);
        u_char buf[32];
        u_char *last = ngx_snprintf(buf, sizeof(buf), "%L", sum);
        return send_resp(r, 200,
                         (u_char *)"text/plain", 10,
                         buf, last - buf, 1);
    }

    /* Unknown path — return 404 instead of falling through to nginx default */
    ngx_http_discard_request_body(r);
    return send_resp(r, 404,
                     (u_char *)"text/plain", 10,
                     (u_char *)"Not Found", 9, 1);
}

/* ---------- Module boilerplate ---------- */

static char *
ngx_http_httparena(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    ngx_http_core_loc_conf_t *clcf;
    clcf = ngx_http_conf_get_module_loc_conf(cf, ngx_http_core_module);
    clcf->handler = ngx_http_httparena_handler;
    return NGX_CONF_OK;
}

static ngx_command_t ngx_http_httparena_commands[] = {
    {
        ngx_string("httparena"),
        NGX_HTTP_LOC_CONF | NGX_CONF_NOARGS,
        ngx_http_httparena,
        0,
        0,
        NULL
    },
    ngx_null_command
};

static ngx_http_module_t ngx_http_httparena_module_ctx = {
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
};

ngx_module_t ngx_http_httparena_module = {
    NGX_MODULE_V1,
    &ngx_http_httparena_module_ctx,
    ngx_http_httparena_commands,
    NGX_HTTP_MODULE,
    NULL,                                /* init master */
    NULL,                                /* init module */
    NULL,                                /* init process */
    NULL,                                /* init thread */
    NULL,                                /* exit thread */
    NULL,                                /* exit process */
    NULL,                                /* exit master */
    NGX_MODULE_V1_PADDING
};
