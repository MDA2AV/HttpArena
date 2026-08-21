#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>

/* Static files (/static/<name>) are not handled here — the nginx.conf
 * location /static/ block serves them directly from /data/static via
 * nginx core's sendfile-backed file handler, which is both faster and
 * exercises the "real nginx static path" the benchmark is meant to
 * measure. Any request that reaches this module has already missed
 * that more-specific location. */

/* ---------- Dataset (/data/dataset.json) ----------
 *
 * Loaded once per worker at init_process and held as typed fields, not as a
 * rendered fragment: /json/{count}?m={multiplier} has to serialize per
 * request, because the multiplier varies per request template and a body
 * cached by path would return wrong totals.
 *
 * The string fields point into the raw file buffer rather than being copied.
 * They are re-emitted verbatim between quotes, so any escape sequence in the
 * source round-trips exactly. */

#define ARENA_MAX_ITEMS 64
#define ARENA_MAX_TAGS  8

typedef struct {
    int64_t    id, price, quantity, score, rating_count;
    ngx_uint_t active;
    ngx_str_t  name, category;
    ngx_str_t  tags[ARENA_MAX_TAGS];
    ngx_uint_t ntags;
    size_t     max_len;   /* upper bound on this item's serialized length */
} arena_item_t;

static arena_item_t  arena_items[ARENA_MAX_ITEMS];
static ngx_uint_t    arena_item_count;
static size_t        arena_item_max_len;
static u_char       *arena_raw;

/* ---------- Minimal JSON scanner ----------
 *
 * Scoped to the dataset's shape. Values are skipped by type rather than by
 * searching for the next key, so a string value containing something that
 * looks like a key cannot desynchronize the parse. */

static u_char *
json_ws(u_char *p, u_char *e)
{
    while (p < e && (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')) p++;
    return p;
}

/* p at the opening quote. out spans the bytes between the quotes. */
static u_char *
json_string(u_char *p, u_char *e, ngx_str_t *out)
{
    if (p >= e || *p != '"') return NULL;
    p++;
    u_char *start = p;
    while (p < e && *p != '"') {
        if (*p == '\\' && p + 1 < e) p++;
        p++;
    }
    if (p >= e) return NULL;
    if (out) { out->data = start; out->len = p - start; }
    return p + 1;
}

static u_char *json_value(u_char *p, u_char *e);

static u_char *
json_container(u_char *p, u_char *e, u_char close)
{
    p++;                                  /* consume '{' or '[' */
    for ( ;; ) {
        p = json_ws(p, e);
        if (p >= e) return NULL;
        if (*p == close) return p + 1;
        if (*p == ',') { p++; continue; }
        if (close == '}') {               /* key then ':' then value */
            p = json_string(p, e, NULL);
            if (!p) return NULL;
            p = json_ws(p, e);
            if (p >= e || *p != ':') return NULL;
            p++;
            p = json_ws(p, e);
        }
        p = json_value(p, e);
        if (!p) return NULL;
    }
}

static u_char *
json_value(u_char *p, u_char *e)
{
    if (p >= e) return NULL;
    if (*p == '"') return json_string(p, e, NULL);
    if (*p == '{') return json_container(p, e, '}');
    if (*p == '[') return json_container(p, e, ']');
    while (p < e && *p != ',' && *p != '}' && *p != ']'
           && *p != ' ' && *p != '\t' && *p != '\r' && *p != '\n') p++;
    return p;
}

static int64_t
json_int(u_char *p, u_char *e)
{
    int64_t n = 0;
    int neg = 0;
    if (p < e && *p == '-') { neg = 1; p++; }
    while (p < e && *p >= '0' && *p <= '9') { n = n * 10 + (*p - '0'); p++; }
    return neg ? -n : n;
}

static u_char *
arena_parse_item(u_char *p, u_char *e, arena_item_t *it)
{
    ngx_str_t key;

    p++;                                  /* consume '{' */
    for ( ;; ) {
        p = json_ws(p, e);
        if (p >= e) return NULL;
        if (*p == '}') { p++; break; }
        if (*p == ',') { p++; continue; }

        u_char *after = json_string(p, e, &key);
        if (!after) return NULL;
        p = json_ws(after, e);
        if (p >= e || *p != ':') return NULL;
        p = json_ws(p + 1, e);
        if (p >= e) return NULL;

#define KEY_IS(s) (key.len == sizeof(s) - 1 && ngx_strncmp(key.data, s, sizeof(s) - 1) == 0)

        if (KEY_IS("id"))            { it->id = json_int(p, e);       p = json_value(p, e); }
        else if (KEY_IS("price"))    { it->price = json_int(p, e);    p = json_value(p, e); }
        else if (KEY_IS("quantity")) { it->quantity = json_int(p, e); p = json_value(p, e); }
        else if (KEY_IS("active"))   { it->active = (*p == 't');      p = json_value(p, e); }
        else if (KEY_IS("name"))     { p = json_string(p, e, &it->name); }
        else if (KEY_IS("category")) { p = json_string(p, e, &it->category); }
        else if (KEY_IS("tags")) {
            if (*p != '[') return NULL;
            p++;
            for ( ;; ) {
                p = json_ws(p, e);
                if (p >= e) return NULL;
                if (*p == ']') { p++; break; }
                if (*p == ',') { p++; continue; }
                ngx_str_t tag;
                p = json_string(p, e, &tag);
                if (!p) return NULL;
                if (it->ntags < ARENA_MAX_TAGS) it->tags[it->ntags++] = tag;
            }
        }
        else if (KEY_IS("rating")) {
            if (*p != '{') return NULL;
            p++;
            for ( ;; ) {
                p = json_ws(p, e);
                if (p >= e) return NULL;
                if (*p == '}') { p++; break; }
                if (*p == ',') { p++; continue; }
                ngx_str_t rk;
                p = json_string(p, e, &rk);
                if (!p) return NULL;
                p = json_ws(p, e);
                if (p >= e || *p != ':') return NULL;
                p = json_ws(p + 1, e);
                if (rk.len == 5 && ngx_strncmp(rk.data, "score", 5) == 0) {
                    it->score = json_int(p, e);
                } else if (rk.len == 5 && ngx_strncmp(rk.data, "count", 5) == 0) {
                    it->rating_count = json_int(p, e);
                }
                p = json_value(p, e);
                if (!p) return NULL;
            }
        }
        else { p = json_value(p, e); }

#undef KEY_IS

        if (!p) return NULL;
    }

    /* Upper bound on the serialized form: fixed punctuation and key names,
     * plus room for five 20-digit integers, the longest boolean, and the
     * variable-length strings. */
    it->max_len = 128 + it->name.len + it->category.len + 5 * 20;
    for (ngx_uint_t i = 0; i < it->ntags; i++) it->max_len += it->tags[i].len + 4;

    return p;
}

static ngx_int_t
arena_load_dataset(ngx_cycle_t *cycle)
{
    const char *path = "/data/dataset.json";
    ngx_fd_t    fd;
    ngx_file_t  file;
    ngx_file_info_t fi;

    ngx_memzero(&file, sizeof(file));
    fd = ngx_open_file(path, NGX_FILE_RDONLY, NGX_FILE_OPEN, 0);
    if (fd == NGX_INVALID_FILE) {
        ngx_log_error(NGX_LOG_ERR, cycle->log, ngx_errno,
                      "httparena: cannot open %s — /json will return 500", path);
        return NGX_OK;
    }
    file.fd = fd;
    file.log = cycle->log;

    if (ngx_fd_info(fd, &fi) == NGX_FILE_ERROR || ngx_file_size(&fi) <= 0) {
        ngx_close_file(fd);
        ngx_log_error(NGX_LOG_ERR, cycle->log, ngx_errno, "httparena: stat %s", path);
        return NGX_OK;
    }

    size_t size = (size_t) ngx_file_size(&fi);
    arena_raw = ngx_alloc(size, cycle->log);
    if (arena_raw == NULL) { ngx_close_file(fd); return NGX_ERROR; }

    ssize_t n = ngx_read_file(&file, arena_raw, size, 0);
    ngx_close_file(fd);
    if (n != (ssize_t) size) {
        ngx_log_error(NGX_LOG_ERR, cycle->log, 0, "httparena: short read on %s", path);
        arena_raw = NULL;
        return NGX_OK;
    }

    u_char *p = json_ws(arena_raw, arena_raw + size);
    u_char *e = arena_raw + size;
    if (p >= e || *p != '[') {
        ngx_log_error(NGX_LOG_ERR, cycle->log, 0, "httparena: %s is not an array", path);
        return NGX_OK;
    }
    p++;

    arena_item_count = 0;
    arena_item_max_len = 0;
    while (arena_item_count < ARENA_MAX_ITEMS) {
        p = json_ws(p, e);
        if (p >= e || *p == ']') break;
        if (*p == ',') { p++; continue; }
        if (*p != '{') break;
        arena_item_t *it = &arena_items[arena_item_count];
        ngx_memzero(it, sizeof(*it));
        p = arena_parse_item(p, e, it);
        if (p == NULL) {
            ngx_log_error(NGX_LOG_ERR, cycle->log, 0,
                          "httparena: malformed item %ui in %s", arena_item_count, path);
            arena_item_count = 0;
            return NGX_OK;
        }
        if (it->max_len > arena_item_max_len) arena_item_max_len = it->max_len;
        arena_item_count++;
    }

    ngx_log_error(NGX_LOG_NOTICE, cycle->log, 0,
                  "httparena: loaded %ui dataset items", arena_item_count);
    return NGX_OK;
}

static ngx_int_t
ngx_http_httparena_init_process(ngx_cycle_t *cycle)
{
    return arena_load_dataset(cycle);
}

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

/* ---------- GET /json/{count}?m={multiplier} ---------- */

static ngx_int_t
json_handler(ngx_http_request_t *r, u_char *uri, size_t uri_len)
{
    ngx_http_discard_request_body(r);

    if (arena_item_count == 0) {
        return send_resp(r, 500, (u_char *) "text/plain", 10,
                         (u_char *) "dataset unavailable", 19, 1);
    }

    /* count is the path segment after "/json/" */
    u_char *cp = uri + 6, *ce = uri + uri_len;
    if (cp >= ce) {
        return send_resp(r, 400, (u_char *) "text/plain", 10,
                         (u_char *) "Bad Request", 11, 1);
    }
    int64_t count = 0;
    for (u_char *q = cp; q < ce; q++) {
        if (*q < '0' || *q > '9') { count = -1; break; }
        count = count * 10 + (*q - '0');
        if (count > ARENA_MAX_ITEMS) break;
    }
    if (count < 1 || count > (int64_t) arena_item_count) {
        return send_resp(r, 400, (u_char *) "text/plain", 10,
                         (u_char *) "Bad Request", 11, 1);
    }

    /* m defaults to 1 so a missing multiplier still yields honest totals */
    int64_t m = 1;
    if (r->args.len) {
        u_char *p = r->args.data, *end = p + r->args.len;
        while (p < end) {
            u_char *eq = ngx_strlchr(p, end, '=');
            if (!eq) break;
            u_char *amp = ngx_strlchr(eq + 1, end, '&');
            if (!amp) amp = end;
            if (eq - p == 1 && *p == 'm') { m = parse_int(eq + 1, amp); break; }
            p = (amp < end) ? amp + 1 : end;
        }
    }

    size_t cap = 32 + (size_t) count * arena_item_max_len;
    u_char *body = ngx_pnalloc(r->pool, cap);
    if (body == NULL) return NGX_HTTP_INTERNAL_SERVER_ERROR;

    u_char *o = body;
    o = ngx_cpymem(o, "{\"items\":[", 10);
    for (int64_t i = 0; i < count; i++) {
        arena_item_t *it = &arena_items[i];
        if (i) *o++ = ',';
        o = ngx_sprintf(o,
                        "{\"id\":%L,\"name\":\"%V\",\"category\":\"%V\",\"price\":%L,"
                        "\"quantity\":%L,\"active\":%s,\"tags\":[",
                        it->id, &it->name, &it->category, it->price, it->quantity,
                        it->active ? (u_char *) "true" : (u_char *) "false");
        for (ngx_uint_t t = 0; t < it->ntags; t++) {
            if (t) *o++ = ',';
            *o++ = '"';
            o = ngx_cpymem(o, it->tags[t].data, it->tags[t].len);
            *o++ = '"';
        }
        o = ngx_sprintf(o, "],\"rating\":{\"score\":%L,\"count\":%L},\"total\":%L}",
                        it->score, it->rating_count, it->price * it->quantity * m);
    }
    o = ngx_sprintf(o, "],\"count\":%L}", count);

    return send_resp(r, 200, (u_char *) "application/json", 16, body, o - body, 0);
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

    /* /json/<count> */
    if (uri_len > 6 && ngx_strncmp(uri, "/json/", 6) == 0) {
        return json_handler(r, uri, uri_len);
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
    ngx_http_httparena_init_process,     /* init process */
    NULL,                                /* init thread */
    NULL,                                /* exit thread */
    NULL,                                /* exit process */
    NULL,                                /* exit master */
    NGX_MODULE_V1_PADDING
};
