#define H2O_USE_LIBUV 0

#include <h2o.h>
#include <h2o/http2.h>
#include <h2o/serverutil.h>
#include <cjson/cJSON.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>
#include <sys/socket.h>

static h2o_globalconf_t globalconf;

/* Dataset loaded once at startup; shared read-only across threads. */
static cJSON *dataset = NULL;
static int dataset_size = 0;

static void load_dataset(void)
{
    const char *path = getenv("DATASET_PATH");
    if (!path) path = "/data/dataset.json";
    FILE *f = fopen(path, "rb");
    if (!f) return;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz <= 0) { fclose(f); return; }
    char *buf = malloc((size_t)sz + 1);
    if (!buf) { fclose(f); return; }
    if (fread(buf, 1, sz, f) != (size_t)sz) { free(buf); fclose(f); return; }
    buf[sz] = '\0';
    fclose(f);
    dataset = cJSON_Parse(buf);
    free(buf);
    if (dataset && cJSON_IsArray(dataset)) {
        dataset_size = cJSON_GetArraySize(dataset);
    }
}

static int64_t sum_query_values(h2o_req_t *req)
{
    if (req->query_at == SIZE_MAX) return 0;
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

static int read_m_param(h2o_req_t *req)
{
    if (req->query_at == SIZE_MAX) return 1;
    const char *p = req->path.base + req->query_at + 1;
    const char *end = req->path.base + req->path.len;
    while (p < end) {
        const char *eq = memchr(p, '=', end - p);
        if (!eq) break;
        const char *v = eq + 1;
        const char *amp = memchr(v, '&', end - v);
        if (!amp) amp = end;
        if (eq - p == 1 && *p == 'm') {
            char *ep;
            long n = strtol(v, &ep, 10);
            if (ep > v && ep <= amp) return n == 0 ? 1 : (int)n;
        }
        p = amp < end ? amp + 1 : end;
    }
    return 1;
}

static inline int reject_bad_method(h2o_req_t *req)
{
    if (h2o_memis(req->method.base, req->method.len, H2O_STRLIT("GET"))) return 0;
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

/* GET /baseline2 — sum a+b (same semantics as the h1 /baseline11 GET path). */
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

/* GET /json/{count}?m=M — serialize first N items with total=price*quantity*m. */
static int on_json(h2o_handler_t *h, h2o_req_t *req)
{
    (void)h;
    if (reject_bad_method(req)) return 0;

    /* Parse count from path after "/json/". */
    const char *prefix = "/json/";
    size_t plen = strlen(prefix);
    if (req->path_normalized.len <= plen) {
        h2o_send_error_404(req, "Not Found", "Not Found", 0);
        return 0;
    }
    const char *rest = req->path_normalized.base + plen;
    size_t rest_len = req->path_normalized.len - plen;
    char count_buf[32];
    if (rest_len >= sizeof(count_buf)) rest_len = sizeof(count_buf) - 1;
    memcpy(count_buf, rest, rest_len);
    count_buf[rest_len] = '\0';
    int count = atoi(count_buf);
    if (count < 0) count = 0;
    if (count > dataset_size) count = dataset_size;

    int m = read_m_param(req);

    cJSON *response = cJSON_CreateObject();
    cJSON *items = cJSON_CreateArray();
    for (int i = 0; i < count; i++) {
        cJSON *src = cJSON_GetArrayItem(dataset, i);
        cJSON *dup = cJSON_Duplicate(src, 1);
        cJSON *price_n = cJSON_GetObjectItem(dup, "price");
        cJSON *qty_n = cJSON_GetObjectItem(dup, "quantity");
        long long price = (price_n && cJSON_IsNumber(price_n)) ? (long long)price_n->valuedouble : 0;
        long long qty = (qty_n && cJSON_IsNumber(qty_n)) ? (long long)qty_n->valuedouble : 0;
        double total = (double)(price * qty * (long long)m);
        cJSON_AddNumberToObject(dup, "total", total);
        cJSON_AddItemToArray(items, dup);
    }
    cJSON_AddItemToObject(response, "items", items);
    cJSON_AddNumberToObject(response, "count", count);

    char *body_str = cJSON_PrintUnformatted(response);
    cJSON_Delete(response);
    size_t body_len = body_str ? strlen(body_str) : 0;

    char *body_buf = h2o_mem_alloc_pool(&req->pool, char, body_len);
    if (body_str) memcpy(body_buf, body_str, body_len);
    free(body_str);

    h2o_generator_t gen;
    memset(&gen, 0, sizeof(gen));
    h2o_iovec_t iov = h2o_iovec_init(body_buf, body_len);
    req->res.status = 200;
    req->res.reason = "OK";
    req->res.content_length = body_len;
    h2o_add_header(&req->pool, &req->res.headers, H2O_TOKEN_CONTENT_TYPE,
                   NULL, H2O_STRLIT("application/json"));
    h2o_start_response(req, &gen);
    h2o_send(req, &iov, 1, H2O_SEND_STATE_FINAL);
    return 0;
}

static void register_handler(h2o_hostconf_t *host, const char *path,
                             int (*fn)(h2o_handler_t *, h2o_req_t *))
{
    h2o_pathconf_t *pc = h2o_config_register_path(host, path, 0);
    h2o_handler_t *h = h2o_create_handler(pc, sizeof(*h));
    h->on_req = fn;
}

static void setup_host(h2o_hostconf_t *host)
{
    register_handler(host, "/baseline2", on_baseline2);
    register_handler(host, "/json/", on_json);
}

static int create_listener(int port)
{
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { close(fd); return -1; }
    if (listen(fd, 4096) < 0) { close(fd); return -1; }
    return fd;
}

/* h2c-only accept callback: h2o_http2_accept bypasses h2o's h1/h2 sniff and
 * expects the HTTP/2 client preface immediately. Plain HTTP/1.1 clients fail
 * protocol negotiation at the h2 framing layer and the connection is dropped,
 * which gives us the h2c-only behavior validate.sh asserts. */
static void on_accept_h2c(h2o_socket_t *listener, const char *err)
{
    (void)err;
    h2o_accept_ctx_t *ctx = listener->data;
    h2o_socket_t *sock;
    while ((sock = h2o_evloop_socket_accept(listener)) != NULL) {
        struct timeval now;
        gettimeofday(&now, NULL);
        h2o_http2_accept(ctx, sock, now);
    }
}

static void *worker_run(void *arg)
{
    (void)arg;
    h2o_evloop_t *loop = h2o_evloop_create();
    h2o_context_t ctx;
    h2o_context_init(&ctx, loop, &globalconf);

    h2o_accept_ctx_t accept_ctx;
    memset(&accept_ctx, 0, sizeof(accept_ctx));
    accept_ctx.ctx = &ctx;
    accept_ctx.hosts = globalconf.hosts;

    int fd = create_listener(8082);
    if (fd >= 0) {
        h2o_socket_t *sock = h2o_evloop_socket_create(loop, fd, H2O_SOCKET_FLAG_DONT_READ);
        sock->data = &accept_ctx;
        h2o_socket_read_start(sock, on_accept_h2c);
    }

    while (h2o_evloop_run(loop, INT32_MAX) == 0)
        ;
    return NULL;
}

int main(void)
{
    signal(SIGPIPE, SIG_IGN);
    load_dataset();

    h2o_config_init(&globalconf);
    globalconf.server_name = h2o_iovec_init(H2O_STRLIT("h2o"));

    h2o_hostconf_t *host = h2o_config_register_host(
        &globalconf, h2o_iovec_init(H2O_STRLIT("default")), 8082);
    setup_host(host);

    int nthreads = sysconf(_SC_NPROCESSORS_ONLN);
    if (nthreads < 1) nthreads = 1;

    for (int i = 1; i < nthreads; i++) {
        pthread_t t;
        pthread_create(&t, NULL, worker_run, NULL);
    }
    worker_run(NULL);
    return 0;
}
