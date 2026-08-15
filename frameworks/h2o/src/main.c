#define H2O_USE_LIBUV 0

#include <h2o.h>
#include <h2o/serverutil.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <openssl/ssl.h>

static h2o_globalconf_t globalconf;
static SSL_CTX *ssl_ctx;      /* 8443: ALPN h2 */
static SSL_CTX *ssl_ctx_h1;   /* 8081: no ALPN, so clients stay on HTTP/1.1 */
/* Pre-loaded static files */
#define MAX_STATIC_FILES 32
typedef struct {
    const char *name;
    const char *content_type;
    char *data;
    size_t len;
} static_file_t;
static static_file_t static_files[MAX_STATIC_FILES];
static int static_file_count;

/* ---------- Dataset (/data/dataset.json) ----------
 *
 * Read once at startup and held as typed fields, not as a rendered fragment:
 * /json/{count}?m={multiplier} has to serialize per request, because the
 * multiplier varies per request template and a body cached by path would
 * return wrong totals.
 *
 * String fields point into the raw file buffer instead of being copied. They
 * are re-emitted verbatim between quotes, so any escape sequence in the source
 * round-trips exactly. */

#define ARENA_MAX_ITEMS 64
#define ARENA_MAX_TAGS  8

typedef struct {
    int64_t id, price, quantity, score, rating_count;
    int active;
    h2o_iovec_t name, category;
    h2o_iovec_t tags[ARENA_MAX_TAGS];
    int ntags;
    size_t max_len;      /* upper bound on this item's serialized length */
} arena_item_t;

static arena_item_t arena_items[ARENA_MAX_ITEMS];
static int arena_item_count;
static size_t arena_item_max_len;

/* Minimal JSON scanner, scoped to the dataset's shape. Values are skipped by
 * type rather than by searching for the next key, so a string value that looks
 * like a key cannot desynchronize the parse. */

static char *json_ws(char *p, char *e)
{
    while (p < e && (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')) p++;
    return p;
}

/* p at the opening quote; out spans the bytes between the quotes */
static char *json_string(char *p, char *e, h2o_iovec_t *out)
{
    if (p >= e || *p != '"') return NULL;
    p++;
    char *start = p;
    while (p < e && *p != '"') {
        if (*p == '\\' && p + 1 < e) p++;
        p++;
    }
    if (p >= e) return NULL;
    if (out != NULL) *out = h2o_iovec_init(start, (size_t)(p - start));
    return p + 1;
}

static char *json_value(char *p, char *e);

static char *json_container(char *p, char *e, char close)
{
    p++;                                  /* consume '{' or '[' */
    for (;;) {
        p = json_ws(p, e);
        if (p >= e) return NULL;
        if (*p == close) return p + 1;
        if (*p == ',') { p++; continue; }
        if (close == '}') {
            p = json_string(p, e, NULL);
            if (p == NULL) return NULL;
            p = json_ws(p, e);
            if (p >= e || *p != ':') return NULL;
            p = json_ws(p + 1, e);
        }
        p = json_value(p, e);
        if (p == NULL) return NULL;
    }
}

static char *json_value(char *p, char *e)
{
    if (p >= e) return NULL;
    if (*p == '"') return json_string(p, e, NULL);
    if (*p == '{') return json_container(p, e, '}');
    if (*p == '[') return json_container(p, e, ']');
    while (p < e && *p != ',' && *p != '}' && *p != ']'
           && *p != ' ' && *p != '\t' && *p != '\r' && *p != '\n') p++;
    return p;
}

static int64_t json_int(char *p, char *e)
{
    int64_t n = 0;
    int neg = 0;
    if (p < e && *p == '-') { neg = 1; p++; }
    while (p < e && *p >= '0' && *p <= '9') { n = n * 10 + (*p - '0'); p++; }
    return neg ? -n : n;
}

#define KEY_IS(k, s) ((k).len == sizeof(s) - 1 && memcmp((k).base, s, sizeof(s) - 1) == 0)

static char *arena_parse_item(char *p, char *e, arena_item_t *it)
{
    h2o_iovec_t key;

    p++;                                  /* consume '{' */
    for (;;) {
        p = json_ws(p, e);
        if (p >= e) return NULL;
        if (*p == '}') { p++; break; }
        if (*p == ',') { p++; continue; }

        char *after = json_string(p, e, &key);
        if (after == NULL) return NULL;
        p = json_ws(after, e);
        if (p >= e || *p != ':') return NULL;
        p = json_ws(p + 1, e);
        if (p >= e) return NULL;

        if (KEY_IS(key, "id"))            { it->id = json_int(p, e);       p = json_value(p, e); }
        else if (KEY_IS(key, "price"))    { it->price = json_int(p, e);    p = json_value(p, e); }
        else if (KEY_IS(key, "quantity")) { it->quantity = json_int(p, e); p = json_value(p, e); }
        else if (KEY_IS(key, "active"))   { it->active = (*p == 't');      p = json_value(p, e); }
        else if (KEY_IS(key, "name"))     { p = json_string(p, e, &it->name); }
        else if (KEY_IS(key, "category")) { p = json_string(p, e, &it->category); }
        else if (KEY_IS(key, "tags")) {
            if (*p != '[') return NULL;
            p++;
            for (;;) {
                p = json_ws(p, e);
                if (p >= e) return NULL;
                if (*p == ']') { p++; break; }
                if (*p == ',') { p++; continue; }
                h2o_iovec_t tag;
                p = json_string(p, e, &tag);
                if (p == NULL) return NULL;
                if (it->ntags < ARENA_MAX_TAGS) it->tags[it->ntags++] = tag;
            }
        }
        else if (KEY_IS(key, "rating")) {
            if (*p != '{') return NULL;
            p++;
            for (;;) {
                p = json_ws(p, e);
                if (p >= e) return NULL;
                if (*p == '}') { p++; break; }
                if (*p == ',') { p++; continue; }
                h2o_iovec_t rk;
                p = json_string(p, e, &rk);
                if (p == NULL) return NULL;
                p = json_ws(p, e);
                if (p >= e || *p != ':') return NULL;
                p = json_ws(p + 1, e);
                if (KEY_IS(rk, "score"))      it->score = json_int(p, e);
                else if (KEY_IS(rk, "count")) it->rating_count = json_int(p, e);
                p = json_value(p, e);
                if (p == NULL) return NULL;
            }
        }
        else { p = json_value(p, e); }

        if (p == NULL) return NULL;
    }

    /* Upper bound on the serialized form: fixed punctuation and key names,
     * plus five 20-digit integers, the longest boolean, and the strings. */
    it->max_len = 128 + it->name.len + it->category.len + 5 * 20;
    for (int i = 0; i < it->ntags; i++) it->max_len += it->tags[i].len + 4;

    return p;
}

#undef KEY_IS

/* A missing or malformed dataset leaves arena_item_count at 0; /json then
 * answers 500 rather than taking every other profile down with it. */
static void load_dataset(void)
{
    FILE *f = fopen("/data/dataset.json", "rb");
    if (f == NULL) {
        fprintf(stderr, "dataset: cannot open /data/dataset.json — /json will 500\n");
        return;
    }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz <= 0) { fclose(f); return; }

    char *raw = malloc((size_t)sz);
    if (raw == NULL) { fclose(f); return; }
    if (fread(raw, 1, (size_t)sz, f) != (size_t)sz) {
        fclose(f);
        free(raw);
        fprintf(stderr, "dataset: short read\n");
        return;
    }
    fclose(f);

    char *p = json_ws(raw, raw + sz), *e = raw + sz;
    if (p >= e || *p != '[') {
        fprintf(stderr, "dataset: not an array\n");
        return;
    }
    p++;

    while (arena_item_count < ARENA_MAX_ITEMS) {
        p = json_ws(p, e);
        if (p >= e || *p == ']') break;
        if (*p == ',') { p++; continue; }
        if (*p != '{') break;
        arena_item_t *it = &arena_items[arena_item_count];
        memset(it, 0, sizeof(*it));
        p = arena_parse_item(p, e, it);
        if (p == NULL) {
            fprintf(stderr, "dataset: malformed item %d\n", arena_item_count);
            arena_item_count = 0;
            return;
        }
        if (it->max_len > arena_item_max_len) arena_item_max_len = it->max_len;
        arena_item_count++;
    }
    printf("Loaded %d dataset items\n", arena_item_count);
}

/* Parse query string values and return their sum */
static int64_t sum_query_values(h2o_req_t *req)
{
    if (req->query_at == SIZE_MAX)
        return 0;
    int64_t sum = 0;
    const char *p = req->path.base + req->query_at + 1;
    const char *end = req->path.base + req->path.len;
    while (p < end) {
        const char *eq = memchr(p, '=', end - p);
        if (!eq) break;
        const char *v = eq + 1;
        const char *amp = memchr(v, '&', end - v);
        if (!amp) amp = end;
        char *ep;
        long long n = strtoll(v, &ep, 10);
        if (ep > v && ep <= amp) sum += n;
        p = amp < end ? amp + 1 : end;
    }
    return sum;
}

/* Method check helper — returns true if method is not GET/HEAD/POST */
static inline int reject_bad_method(h2o_req_t *req)
{
    if (h2o_memis(req->method.base, req->method.len, H2O_STRLIT("GET"))
        || h2o_memis(req->method.base, req->method.len, H2O_STRLIT("HEAD"))
        || h2o_memis(req->method.base, req->method.len, H2O_STRLIT("POST"))) {
        return 0;
    }
    req->res.status = 405;
    req->res.reason = "Method Not Allowed";
    req->res.content_length = 18;
    h2o_add_header(&req->pool, &req->res.headers, H2O_TOKEN_CONTENT_TYPE,
                   NULL, H2O_STRLIT("text/plain"));
    h2o_generator_t gen;
    memset(&gen, 0, sizeof(gen));
    h2o_iovec_t body = {H2O_STRLIT("Method Not Allowed")};
    h2o_start_response(req, &gen);
    h2o_send(req, &body, 1, H2O_SEND_STATE_FINAL);
    return 1;
}

/* GET /pipeline — return "ok" (zero-copy static response) */
static int on_pipeline(h2o_handler_t *h, h2o_req_t *req)
{
    static h2o_iovec_t body = {H2O_STRLIT("ok")};
    (void)h;
    if (reject_bad_method(req)) return 0;
    h2o_generator_t gen;
    memset(&gen, 0, sizeof(gen));
    req->res.status = 200;
    req->res.reason = "OK";
    req->res.content_length = body.len;
    h2o_add_header(&req->pool, &req->res.headers, H2O_TOKEN_CONTENT_TYPE,
                   NULL, H2O_STRLIT("text/plain"));
    h2o_start_response(req, &gen);
    h2o_send(req, &body, 1, H2O_SEND_STATE_FINAL);
    return 0;
}

/* GET|POST /baseline11 — sum query params (+ body for POST) */
static int on_baseline11(h2o_handler_t *h, h2o_req_t *req)
{
    (void)h;
    if (reject_bad_method(req)) return 0;
    int64_t sum = sum_query_values(req);
    if (h2o_memis(req->method.base, req->method.len, H2O_STRLIT("POST"))
        && req->entity.len > 0) {
        const char *p = req->entity.base;
        const char *end = p + req->entity.len;
        while (p < end && *p <= ' ') p++;
        char *ep;
        long long n = strtoll(p, &ep, 10);
        if (ep > p) sum += n;
    }
    char buf[32];
    int len = snprintf(buf, sizeof(buf), "%lld", (long long)sum);
    h2o_generator_t gen;
    memset(&gen, 0, sizeof(gen));
    h2o_iovec_t body = h2o_iovec_init(buf, len);
    req->res.status = 200;
    req->res.reason = "OK";
    req->res.content_length = len;
    h2o_add_header(&req->pool, &req->res.headers, H2O_TOKEN_CONTENT_TYPE,
                   NULL, H2O_STRLIT("text/plain"));
    h2o_start_response(req, &gen);
    h2o_send(req, &body, 1, H2O_SEND_STATE_FINAL);
    return 0;
}

/* GET /baseline2 — sum query params */
static int on_baseline2(h2o_handler_t *h, h2o_req_t *req)
{
    (void)h;
    if (reject_bad_method(req)) return 0;
    int64_t sum = sum_query_values(req);
    char buf[32];
    int len = snprintf(buf, sizeof(buf), "%lld", (long long)sum);
    h2o_generator_t gen;
    memset(&gen, 0, sizeof(gen));
    h2o_iovec_t body = h2o_iovec_init(buf, len);
    req->res.status = 200;
    req->res.reason = "OK";
    req->res.content_length = len;
    h2o_add_header(&req->pool, &req->res.headers, H2O_TOKEN_CONTENT_TYPE,
                   NULL, H2O_STRLIT("text/plain"));
    h2o_start_response(req, &gen);
    h2o_send(req, &body, 1, H2O_SEND_STATE_FINAL);
    return 0;
}

/* GET /json/{count}?m={multiplier} — serialize per request from the dataset */
static int on_json(h2o_handler_t *h, h2o_req_t *req)
{
    (void)h;
    if (reject_bad_method(req)) return 0;

    if (arena_item_count == 0) {
        h2o_send_error_500(req, "Internal Server Error", "dataset unavailable", 0);
        return 0;
    }

    /* count is the path segment after "/json/" */
    if (req->path_normalized.len <= 6) {
        h2o_send_error_400(req, "Bad Request", "Bad Request", 0);
        return 0;
    }
    const char *cp = req->path_normalized.base + 6;
    const char *ce = req->path_normalized.base + req->path_normalized.len;
    int64_t count = 0;
    for (const char *q = cp; q < ce; q++) {
        if (*q < '0' || *q > '9') { count = -1; break; }
        count = count * 10 + (*q - '0');
        if (count > ARENA_MAX_ITEMS) break;
    }
    if (count < 1 || count > (int64_t)arena_item_count) {
        h2o_send_error_400(req, "Bad Request", "Bad Request", 0);
        return 0;
    }

    /* m defaults to 1 so a missing multiplier still yields honest totals */
    int64_t m = 1;
    if (req->query_at != SIZE_MAX) {
        const char *p = req->path.base + req->query_at + 1;
        const char *end = req->path.base + req->path.len;
        while (p < end) {
            const char *eq = memchr(p, '=', end - p);
            if (eq == NULL) break;
            const char *amp = memchr(eq + 1, '&', end - (eq + 1));
            if (amp == NULL) amp = end;
            if (eq - p == 1 && *p == 'm') {
                char *ep;
                long long n = strtoll(eq + 1, &ep, 10);
                if (ep > eq + 1) m = n;
                break;
            }
            p = amp < end ? amp + 1 : end;
        }
    }

    size_t cap = 32 + (size_t)count * arena_item_max_len;
    char *body = h2o_mem_alloc_pool(&req->pool, char, cap);
    char *o = body;

    memcpy(o, "{\"items\":[", 10);
    o += 10;
    for (int64_t i = 0; i < count; i++) {
        arena_item_t *it = &arena_items[i];
        if (i) *o++ = ',';
        o += sprintf(o, "{\"id\":%lld,\"name\":\"", (long long)it->id);
        memcpy(o, it->name.base, it->name.len);            o += it->name.len;
        memcpy(o, "\",\"category\":\"", 14);                o += 14;
        memcpy(o, it->category.base, it->category.len);     o += it->category.len;
        o += sprintf(o, "\",\"price\":%lld,\"quantity\":%lld,\"active\":%s,\"tags\":[",
                     (long long)it->price, (long long)it->quantity,
                     it->active ? "true" : "false");
        for (int t = 0; t < it->ntags; t++) {
            if (t) *o++ = ',';
            *o++ = '"';
            memcpy(o, it->tags[t].base, it->tags[t].len);   o += it->tags[t].len;
            *o++ = '"';
        }
        o += sprintf(o, "],\"rating\":{\"score\":%lld,\"count\":%lld},\"total\":%lld}",
                     (long long)it->score, (long long)it->rating_count,
                     (long long)(it->price * it->quantity * m));
    }
    o += sprintf(o, "],\"count\":%lld}", (long long)count);

    h2o_generator_t gen;
    memset(&gen, 0, sizeof(gen));
    h2o_iovec_t out = h2o_iovec_init(body, (size_t)(o - body));
    req->res.status = 200;
    req->res.reason = "OK";
    req->res.content_length = out.len;
    h2o_add_header(&req->pool, &req->res.headers, H2O_TOKEN_CONTENT_TYPE,
                   NULL, H2O_STRLIT("application/json"));
    h2o_start_response(req, &gen);
    h2o_send(req, &out, 1, H2O_SEND_STATE_FINAL);
    return 0;
}

/* GET /static/<filename> — serve pre-loaded static files */
static int on_static(h2o_handler_t *h, h2o_req_t *req)
{
    (void)h;
    if (reject_bad_method(req)) return 0;
    /* path is /static/<filename>, extract filename after "/static/" (8 chars) */
    if (req->path_normalized.len <= 8) {
        h2o_send_error_404(req, "Not Found", "Not Found", 0);
        return 0;
    }
    const char *fname = req->path_normalized.base + 8;
    size_t fname_len = req->path_normalized.len - 8;

    for (int i = 0; i < static_file_count; i++) {
        size_t nlen = strlen(static_files[i].name);
        if (nlen == fname_len && memcmp(static_files[i].name, fname, nlen) == 0) {
            h2o_generator_t gen;
            memset(&gen, 0, sizeof(gen));
            h2o_iovec_t body = h2o_iovec_init(static_files[i].data, static_files[i].len);
            req->res.status = 200;
            req->res.reason = "OK";
            req->res.content_length = static_files[i].len;
            h2o_add_header(&req->pool, &req->res.headers, H2O_TOKEN_CONTENT_TYPE,
                           NULL, static_files[i].content_type, strlen(static_files[i].content_type));
            h2o_start_response(req, &gen);
            h2o_send(req, &body, 1, H2O_SEND_STATE_FINAL);
            return 0;
        }
    }
    h2o_send_error_404(req, "Not Found", "Not Found", 0);
    return 0;
}

/* Load all static files from /data/static/ into memory */
static void load_static_files(void)
{
    static const struct { const char *name; const char *ct; } entries[] = {
        {"reset.css",       "text/css"},
        {"layout.css",      "text/css"},
        {"theme.css",       "text/css"},
        {"components.css",  "text/css"},
        {"utilities.css",   "text/css"},
        {"analytics.js",    "application/javascript"},
        {"helpers.js",      "application/javascript"},
        {"app.js",          "application/javascript"},
        {"vendor.js",       "application/javascript"},
        {"router.js",       "application/javascript"},
        {"header.html",     "text/html"},
        {"footer.html",     "text/html"},
        {"regular.woff2",   "font/woff2"},
        {"bold.woff2",      "font/woff2"},
        {"logo.svg",        "image/svg+xml"},
        {"icon-sprite.svg", "image/svg+xml"},
        {"hero.webp",       "image/webp"},
        {"thumb1.webp",     "image/webp"},
        {"thumb2.webp",     "image/webp"},
        {"manifest.json",   "application/json"},
    };
    int n = sizeof(entries) / sizeof(entries[0]);
    for (int i = 0; i < n && static_file_count < MAX_STATIC_FILES; i++) {
        char path[256];
        snprintf(path, sizeof(path), "/data/static/%s", entries[i].name);
        FILE *f = fopen(path, "rb");
        if (!f) continue;
        fseek(f, 0, SEEK_END);
        long sz = ftell(f);
        fseek(f, 0, SEEK_SET);
        char *data = malloc(sz);
        if (!data) { fclose(f); continue; }
        fread(data, 1, sz, f);
        fclose(f);
        static_files[static_file_count].name = entries[i].name;
        static_files[static_file_count].content_type = entries[i].ct;
        static_files[static_file_count].data = data;
        static_files[static_file_count].len = sz;
        static_file_count++;
    }
    printf("Loaded %d static files\n", static_file_count);
}

static h2o_pathconf_t *register_handler(h2o_hostconf_t *host, const char *path,
                              int (*fn)(h2o_handler_t *, h2o_req_t *))
{
    h2o_pathconf_t *pc = h2o_config_register_path(host, path, 0);
    h2o_handler_t *h = h2o_create_handler(pc, sizeof(*h));
    h->on_req = fn;
    return pc;
}

static void setup_host(h2o_hostconf_t *host)
{
    register_handler(host, "/pipeline", on_pipeline);
    register_handler(host, "/baseline11", on_baseline11);
    register_handler(host, "/baseline2", on_baseline2);
    register_handler(host, "/json", on_json);
    register_handler(host, "/static", on_static);
}

/* Create listener socket with SO_REUSEPORT */
static int create_listener(int port)
{
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, sizeof(on));
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));
    setsockopt(fd, IPPROTO_TCP, TCP_QUICKACK, &on, sizeof(on));

    int defer = 10;
    setsockopt(fd, IPPROTO_TCP, TCP_DEFER_ACCEPT, &defer, sizeof(defer));

    int qlen = 4096;
    setsockopt(fd, IPPROTO_TCP, TCP_FASTOPEN, &qlen, sizeof(qlen));

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { close(fd); return -1; }
    if (listen(fd, 4096) < 0) { close(fd); return -1; }
    return fd;
}

/* Accept callback */
static void on_accept(h2o_socket_t *listener, const char *err)
{
    if (err) return;
    h2o_accept_ctx_t *ctx = listener->data;
    h2o_socket_t *sock;
    while ((sock = h2o_evloop_socket_accept(listener)) != NULL)
        h2o_accept(ctx, sock);
}

/* Worker thread: own event loop + listeners */
static void *worker_run(void *arg)
{
    (void)arg;
    h2o_evloop_t *loop = h2o_evloop_create();
    h2o_context_t ctx;
    h2o_context_init(&ctx, loop, &globalconf);

    /* HTTP/1.1 on port 8080 */
    h2o_accept_ctx_t accept_http;
    memset(&accept_http, 0, sizeof(accept_http));
    accept_http.ctx = &ctx;
    accept_http.hosts = globalconf.hosts;

    int fd = create_listener(8080);
    if (fd >= 0) {
        h2o_socket_t *sock = h2o_evloop_socket_create(loop, fd,
                                                       H2O_SOCKET_FLAG_DONT_READ);
        sock->data = &accept_http;
        h2o_socket_read_start(sock, on_accept);
    }

    /* HTTPS/H1 on port 8081 (json-tls, static-tls) */
    h2o_accept_ctx_t accept_ssl_h1;
    if (ssl_ctx_h1) {
        memset(&accept_ssl_h1, 0, sizeof(accept_ssl_h1));
        accept_ssl_h1.ctx = &ctx;
        accept_ssl_h1.hosts = globalconf.hosts;
        accept_ssl_h1.ssl_ctx = ssl_ctx_h1;

        int fd_h1 = create_listener(8081);
        if (fd_h1 >= 0) {
            h2o_socket_t *sock = h2o_evloop_socket_create(loop, fd_h1,
                                                           H2O_SOCKET_FLAG_DONT_READ);
            sock->data = &accept_ssl_h1;
            h2o_socket_read_start(sock, on_accept);
        }
    }

    /* HTTPS/H2 on port 8443 */
    h2o_accept_ctx_t accept_ssl;
    if (ssl_ctx) {
        memset(&accept_ssl, 0, sizeof(accept_ssl));
        accept_ssl.ctx = &ctx;
        accept_ssl.hosts = globalconf.hosts;
        accept_ssl.ssl_ctx = ssl_ctx;

        int fd_ssl = create_listener(8443);
        if (fd_ssl >= 0) {
            h2o_socket_t *sock = h2o_evloop_socket_create(loop, fd_ssl,
                                                           H2O_SOCKET_FLAG_DONT_READ);
            sock->data = &accept_ssl;
            h2o_socket_read_start(sock, on_accept);
        }
    }

    while (h2o_evloop_run(loop, INT32_MAX) == 0)
        ;
    return NULL;
}

/* Build one TLS context. alpn_h2 registers the h2 ALPN protocols; without it
 * the server advertises no ALPN and clients stay on HTTP/1.1, which is what
 * the :8081 profiles measure. */
static SSL_CTX *make_tls_ctx(const char *cert, const char *key, int alpn_h2)
{
    SSL_CTX *c = SSL_CTX_new(TLS_server_method());
    if (c == NULL) return NULL;
    SSL_CTX_set_min_proto_version(c, TLS1_2_VERSION);
    if (alpn_h2) h2o_ssl_register_alpn_protocols(c, h2o_http2_alpn_protocols);

    if (SSL_CTX_use_certificate_file(c, cert, SSL_FILETYPE_PEM) != 1 ||
        SSL_CTX_use_PrivateKey_file(c, key, SSL_FILETYPE_PEM) != 1) {
        SSL_CTX_free(c);
        return NULL;
    }
    return c;
}

/* Initialize TLS for HTTP/2 (8443) and HTTP/1.1 (8081) */
static void init_tls(void)
{
    const char *cert = getenv("TLS_CERT");
    const char *key = getenv("TLS_KEY");
    if (!cert) cert = "/certs/server.crt";
    if (!key) key = "/certs/server.key";
    if (access(cert, R_OK) != 0 || access(key, R_OK) != 0) return;

    ssl_ctx = make_tls_ctx(cert, key, 1);
    ssl_ctx_h1 = make_tls_ctx(cert, key, 0);
}

int main(void)
{
    signal(SIGPIPE, SIG_IGN);
    load_static_files();
    load_dataset();
    init_tls();

    h2o_config_init(&globalconf);
    globalconf.server_name = h2o_iovec_init(H2O_STRLIT("h2o"));

    /* Register host for HTTP (8080) */
    h2o_hostconf_t *host_http = h2o_config_register_host(
        &globalconf, h2o_iovec_init(H2O_STRLIT("default")), 8080);
    setup_host(host_http);

    /* Register host for HTTPS/H1 (8081) */
    if (ssl_ctx_h1) {
        h2o_hostconf_t *host_h1 = h2o_config_register_host(
            &globalconf, h2o_iovec_init(H2O_STRLIT("default")), 8081);
        setup_host(host_h1);
    }

    /* Register host for HTTPS (8443) */
    if (ssl_ctx) {
        h2o_hostconf_t *host_ssl = h2o_config_register_host(
            &globalconf, h2o_iovec_init(H2O_STRLIT("default")), 8443);
        setup_host(host_ssl);
    }

    int nthreads = sysconf(_SC_NPROCESSORS_ONLN);
    if (nthreads < 1) nthreads = 1;

    for (int i = 1; i < nthreads; i++) {
        pthread_t t;
        pthread_create(&t, NULL, worker_run, NULL);
    }

    worker_run(NULL);
    return 0;
}
