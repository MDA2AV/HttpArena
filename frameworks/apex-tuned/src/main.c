#include "common.h"
#include "http.h"
#include "router.h"
#include "dataset.h"
#include "timer.h"
#include "tls.h"
#include "static_files.h"

typedef struct conn_s conn_t;

struct conn_s {
    int         fd;
    uint32_t    gen;
    bool        is_tls;
    SSL        *ssl;
    bool        tls_handshake_done;

    char       *read_buf;
    size_t      read_cap;
    size_t      read_pos;
    char        inline_read_buf[16384];

    char       *pending_write;
    size_t      pending_write_len;
    size_t      pending_write_sent;

    char        scratch[64];

    bool        parked_in_timer;
    uint64_t    timer_expire_us;
    int64_t     timer_val_ms;

    bool        keep_alive;
    bool        closing;

    conn_t     *next_free;
};

typedef struct {
    int               id;
    int               cpu_id;
    pthread_t         thread;
    int               epoll_fd;
    int               listen_h1_fd;
    int               listen_tls_fd;
    SSL_CTX          *ssl_ctx;
    router_t          router;
    worker_compress_t compress;
    timer_heap_t      timers;
    conn_t           *free_conns;

    int               token_h1;
    int               token_tls;

    char              write_buf[WRITE_BUF_SIZE];
    char              chunk_buf[128 * 1024];
} worker_t;

static volatile bool g_running = true;
static int           g_num_workers = 1;
static worker_t     *g_workers = NULL;
static __thread worker_t *t_worker = NULL;

static void handle_sig(int sig) {
    (void)sig;
    g_running = false;
}

static conn_t* alloc_conn(worker_t *w, int fd, bool is_tls, SSL *ssl) {
    conn_t *c = w->free_conns;
    if (c) {
        w->free_conns = c->next_free;
    } else {
        c = calloc(1, sizeof(conn_t));
        if (!c) return NULL;
        c->read_buf = c->inline_read_buf;
        c->read_cap = sizeof(c->inline_read_buf);
    }
    c->fd = fd;
    c->gen++;
    c->is_tls = is_tls;
    c->ssl = ssl;
    c->tls_handshake_done = false;
    c->read_pos = 0;
    c->pending_write = NULL;
    c->pending_write_len = 0;
    c->pending_write_sent = 0;
    c->parked_in_timer = false;
    c->keep_alive = true;
    c->closing = false;
    c->next_free = NULL;
    return c;
}

static void close_conn(worker_t *w, conn_t *c) {
    if (c->fd >= 0) {
        epoll_ctl(w->epoll_fd, EPOLL_CTL_DEL, c->fd, NULL);
        close(c->fd);
        c->fd = -1;
    }
    if (c->ssl) {
        SSL_free(c->ssl);
        c->ssl = NULL;
    }
    if (c->pending_write) {
        free(c->pending_write);
        c->pending_write = NULL;
    }
    if (c->read_buf != c->inline_read_buf) {
        free(c->read_buf);
        c->read_buf = c->inline_read_buf;
        c->read_cap = sizeof(c->inline_read_buf);
    }
    c->read_pos = 0;
    c->pending_write_len = 0;
    c->pending_write_sent = 0;
    c->parked_in_timer = false;
    c->closing = false;
    c->gen++;

    c->next_free = w->free_conns;
    w->free_conns = c;
}

static void baseline_handler(context_t *ctx) {
    request_t *req = ctx->req;
    response_t *res = ctx->res;
    conn_t *c = (conn_t*)ctx->user_data;

    int64_t sum = 0;
    for (size_t i = 0; i < req->num_params; i++) {
        int64_t v = 0;
        if (parse_i64(req->params[i].val.ptr, req->params[i].val.len, &v)) {
            sum += v;
        }
    }

    if (req->method == HTTP_METHOD_POST && req->body.len > 0) {
        int64_t body_val = 0;
        if (parse_i64(req->body.ptr, req->body.len, &body_val)) {
            sum += body_val;
        }
    }

    size_t len = format_i64(c->scratch, sum);
    res_set_text(res, c->scratch, len);
}

static void pipeline_handler(context_t *ctx) {
    res_set_text(ctx->res, "ok", 2);
}

static void delay_handler(context_t *ctx) {
    request_t *req = ctx->req;
    response_t *res = ctx->res;
    conn_t *c = (conn_t*)ctx->user_data;

    int64_t ms = 0;
    if (req->num_route_params > 0) {
        parse_i64(req->route_params[0].ptr, req->route_params[0].len, &ms);
    }

    if (ms <= 0) {
        size_t len = format_i64(c->scratch, 0);
        res_set_text(res, c->scratch, len);
        return;
    }

    c->parked_in_timer = true;
    c->timer_expire_us = clock_monotonic_us() + (uint64_t)ms * 1000ULL;
    c->timer_val_ms = ms;
    c->keep_alive = req->keep_alive;
    ctx->async_parked = true;
}

static void json_handler(context_t *ctx) {
    request_t *req = ctx->req;
    response_t *res = ctx->res;
    worker_t *w = t_worker;

    int64_t count = 50;
    if (req->num_route_params > 0) {
        parse_i64(req->route_params[0].ptr, req->route_params[0].len, &count);
    }
    if (count < 1) count = 1;
    if (count > 50) count = 50;

    int64_t mult = 1;
    str_view_t m_val;
    if (req_get_query_param(req, "m", &m_val)) {
        parse_i64(m_val.ptr, m_val.len, &mult);
    }

    size_t json_len = json_serialize((size_t)count, mult, w->compress.json_buf, sizeof(w->compress.json_buf));

    bool can_br = (req->accept_encoding.ptr && strcasestr(req->accept_encoding.ptr, "br") != NULL);
    bool can_gz = (req->accept_encoding.ptr && strcasestr(req->accept_encoding.ptr, "gzip") != NULL);

    if (can_gz) {
        size_t comp_len = 0;
        if (compress_gzip(&w->compress, w->compress.json_buf, json_len, w->compress.comp_buf, sizeof(w->compress.comp_buf), &comp_len) == 0) {
            res_set_json(res, w->compress.comp_buf, comp_len);
            res->content_encoding = "gzip";
            return;
        }
    }

    if (can_br) {
        size_t comp_len = 0;
        if (compress_brotli(w->compress.json_buf, json_len, w->compress.comp_buf, sizeof(w->compress.comp_buf), &comp_len) == 0) {
            res_set_json(res, w->compress.comp_buf, comp_len);
            res->content_encoding = "br";
            return;
        }
    }

    res_set_json(res, w->compress.json_buf, json_len);
    res->content_encoding = NULL;
}

static void echo_handler(context_t *ctx) {
    request_t *req = ctx->req;
    response_t *res = ctx->res;
    res_set_binary(res, req->body.ptr, req->body.len, "application/octet-stream");
}

static bool flush_pending_write(worker_t *w, conn_t *c) {
    while (c->pending_write_sent < c->pending_write_len) {
        size_t remaining = c->pending_write_len - c->pending_write_sent;
        ssize_t n = 0;
        if (c->is_tls) {
            int ret = SSL_write(c->ssl, c->pending_write + c->pending_write_sent, (int)remaining);
            if (ret <= 0) {
                int err = SSL_get_error(c->ssl, ret);
                if (err == SSL_ERROR_WANT_WRITE || err == SSL_ERROR_WANT_READ) {
                    return false;
                }
                close_conn(w, c);
                return false;
            }
            n = ret;
        } else {
            n = send(c->fd, c->pending_write + c->pending_write_sent, remaining, MSG_NOSIGNAL);
            if (n < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    return false;
                }
                close_conn(w, c);
                return false;
            }
        }
        c->pending_write_sent += (size_t)n;
    }

    free(c->pending_write);
    c->pending_write = NULL;
    c->pending_write_len = 0;
    c->pending_write_sent = 0;

    struct epoll_event ev = {
        .events = EPOLLIN | EPOLLET | EPOLLRDHUP | EPOLLHUP | EPOLLERR,
        .data.ptr = c
    };
    epoll_ctl(w->epoll_fd, EPOLL_CTL_MOD, c->fd, &ev);

    if (c->closing || !c->keep_alive) {
        close_conn(w, c);
        return false;
    }

    return true;
}

static void flush_data(worker_t *w, conn_t *c, const char *data, size_t len) {
    if (len == 0) return;
    size_t sent = 0;

    while (sent < len) {
        ssize_t n = 0;
        if (c->is_tls) {
            int ret = SSL_write(c->ssl, data + sent, (int)(len - sent));
            if (ret <= 0) {
                int err = SSL_get_error(c->ssl, ret);
                if (err == SSL_ERROR_WANT_WRITE || err == SSL_ERROR_WANT_READ) {
                    break;
                }
                close_conn(w, c);
                return;
            }
            n = ret;
        } else {
            n = send(c->fd, data + sent, len - sent, MSG_NOSIGNAL);
            if (n < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    break;
                }
                close_conn(w, c);
                return;
            }
        }
        sent += (size_t)n;
    }

    if (sent < len) {
        size_t rem = len - sent;
        c->pending_write = malloc(rem);
        if (!c->pending_write) {
            close_conn(w, c);
            return;
        }
        memcpy(c->pending_write, data + sent, rem);
        c->pending_write_len = rem;
        c->pending_write_sent = 0;

        struct epoll_event ev = {
            .events = EPOLLIN | EPOLLOUT | EPOLLET | EPOLLRDHUP | EPOLLHUP | EPOLLERR,
            .data.ptr = c
        };
        epoll_ctl(w->epoll_fd, EPOLL_CTL_MOD, c->fd, &ev);
        return;
    }

    if (c->closing || !c->keep_alive) {
        close_conn(w, c);
    }
}

static void process_requests(worker_t *w, conn_t *c) {
    size_t write_pos = 0;

    while (c->read_pos > 0 && !c->parked_in_timer && !c->closing) {
        request_t req;
        size_t consumed = 0;
        int rc = parse_http_request(c->read_buf, c->read_pos, &req, w->chunk_buf, sizeof(w->chunk_buf), &consumed);

        if (rc == 0) {
            break;
        }
        if (rc < 0) {
            close_conn(w, c);
            return;
        }

        c->keep_alive = req.keep_alive;
        response_t res;
        res_init(&res, c->keep_alive);

        bool async_parked = false;
        if (!router_dispatch(&w->router, &req, &res, c, &async_parked)) {
            res_set_status(&res, 404);
            res_set_text(&res, "Not Found", 9);
        }

        if (async_parked) {
            timer_heap_push(&w->timers, c->timer_expire_us, c, c->gen, c->timer_val_ms);
            if (consumed < c->read_pos) {
                memmove(c->read_buf, c->read_buf + consumed, c->read_pos - consumed);
                c->read_pos -= consumed;
            } else {
                c->read_pos = 0;
            }
            break;
        }

        size_t remaining_space = sizeof(w->write_buf) - write_pos;
        size_t written = res_serialize(&res, w->write_buf + write_pos, remaining_space);
        if (res.body_needs_free && res.body) {
            free((void*)res.body);
        }

        if (written == 0) {
            close_conn(w, c);
            return;
        }

        write_pos += written;

        if (consumed < c->read_pos) {
            memmove(c->read_buf, c->read_buf + consumed, c->read_pos - consumed);
            c->read_pos -= consumed;
        } else {
            c->read_pos = 0;
        }

        if (!c->keep_alive) {
            c->closing = true;
        }
    }

    if (write_pos > 0) {
        flush_data(w, c, w->write_buf, write_pos);
    }
}

static void handle_timer_expiration(worker_t *w, conn_t *c, int64_t delay_ms) {
    c->parked_in_timer = false;

    static const char res_delay_10[] =
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: text/plain\r\n"
        "Content-Length: 2\r\n"
        "Connection: keep-alive\r\n\r\n10";
    static const size_t res_delay_10_len = sizeof(res_delay_10) - 1;

    if (delay_ms == 10 && c->keep_alive) {
        flush_data(w, c, res_delay_10, res_delay_10_len);
    } else {
        response_t res;
        res_init(&res, c->keep_alive);
        char buf[24];
        size_t len = format_i64(buf, delay_ms);
        res_set_text(&res, buf, len);

        size_t written = res_serialize(&res, w->write_buf, sizeof(w->write_buf));
        if (written > 0) {
            flush_data(w, c, w->write_buf, written);
        }
    }

    if (c->fd >= 0 && c->read_pos > 0 && !c->closing && !c->parked_in_timer) {
        process_requests(w, c);
    }
}

static void* worker_main(void *arg) {
    worker_t *w = (worker_t*)arg;
    t_worker = w;

    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(w->cpu_id, &cpuset);
    pthread_setaffinity_np(pthread_self(), sizeof(cpuset), &cpuset);

    struct epoll_event events[MAX_EVENTS];

    while (g_running) {
        uint64_t now_us = clock_monotonic_us();
        int64_t timeout_us = timer_heap_next_timeout_us(&w->timers, now_us);

        int nfds;
        if (timeout_us < 0) {
            nfds = epoll_wait(w->epoll_fd, events, MAX_EVENTS, -1);
        } else if (timeout_us == 0) {
            nfds = epoll_wait(w->epoll_fd, events, MAX_EVENTS, 0);
        } else {
#if defined(__linux__)
            struct timespec ts = {
                .tv_sec = (time_t)(timeout_us / 1000000),
                .tv_nsec = (long)((timeout_us % 1000000) * 1000)
            };
            nfds = epoll_pwait2(w->epoll_fd, events, MAX_EVENTS, &ts, NULL);
#else
            int timeout_ms = (int)((timeout_us + 999) / 1000);
            nfds = epoll_wait(w->epoll_fd, events, MAX_EVENTS, timeout_ms);
#endif
        }
        if (nfds < 0) {
            if (errno == EINTR) continue;
            break;
        }

        now_us = clock_monotonic_us();
        timer_entry_t te;
        while (timer_heap_peek(&w->timers, &te)) {
            if (te.expire_at_us > now_us) break;
            timer_heap_pop(&w->timers, &te);
            conn_t *c = (conn_t*)te.conn_ptr;
            if (c && c->gen == te.conn_gen && c->parked_in_timer) {
                handle_timer_expiration(w, c, te.delay_ms);
            }
        }

        for (int i = 0; i < nfds; i++) {
            void *ptr = events[i].data.ptr;
            uint32_t evs = events[i].events;

            if (ptr == &w->token_h1) {
                while (true) {
                    int cfd = accept4(w->listen_h1_fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
                    if (cfd < 0) break;

                    set_sock_opts(cfd);
                    conn_t *c = alloc_conn(w, cfd, false, NULL);
                    if (!c) { close(cfd); continue; }

                    struct epoll_event ev = {
                        .events = EPOLLIN | EPOLLET | EPOLLRDHUP | EPOLLHUP | EPOLLERR,
                        .data.ptr = c
                    };
                    epoll_ctl(w->epoll_fd, EPOLL_CTL_ADD, cfd, &ev);
                }
                continue;
            }

            if (w->listen_tls_fd >= 0 && ptr == &w->token_tls) {
                while (true) {
                    int cfd = accept4(w->listen_tls_fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
                    if (cfd < 0) break;

                    set_sock_opts(cfd);
                    SSL *ssl = SSL_new(w->ssl_ctx);
                    if (!ssl) { close(cfd); continue; }
                    SSL_set_fd(ssl, cfd);
                    SSL_set_accept_state(ssl);

                    conn_t *c = alloc_conn(w, cfd, true, ssl);
                    if (!c) { SSL_free(ssl); close(cfd); continue; }

                    struct epoll_event ev = {
                        .events = EPOLLIN | EPOLLOUT | EPOLLET | EPOLLRDHUP | EPOLLHUP | EPOLLERR,
                        .data.ptr = c
                    };
                    epoll_ctl(w->epoll_fd, EPOLL_CTL_ADD, cfd, &ev);
                }
                continue;
            }

            conn_t *c = (conn_t*)ptr;
            if (!c || c->fd < 0) continue;

            if (evs & (EPOLLRDHUP | EPOLLHUP | EPOLLERR)) {
                close_conn(w, c);
                continue;
            }

            if (c->is_tls && !c->tls_handshake_done) {
                int ret = SSL_accept(c->ssl);
                if (ret <= 0) {
                    int err = SSL_get_error(c->ssl, ret);
                    if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE) {
                        continue;
                    }
                    close_conn(w, c);
                    continue;
                }
                c->tls_handshake_done = true;
                struct epoll_event ev = {
                    .events = EPOLLIN | EPOLLET | EPOLLRDHUP | EPOLLHUP | EPOLLERR,
                    .data.ptr = c
                };
                epoll_ctl(w->epoll_fd, EPOLL_CTL_MOD, c->fd, &ev);
            }

            if (evs & EPOLLOUT) {
                if (c->pending_write) {
                    if (!flush_pending_write(w, c)) {
                        continue;
                    }
                }
            }

            if (evs & EPOLLIN) {
                while (true) {
                    if (c->read_pos == c->read_cap) {
                        size_t new_cap = c->read_cap * 2;
                        if (new_cap < 65536) new_cap = 65536;
                        if (new_cap > 512 * 1024) new_cap = 512 * 1024;
                        if (new_cap > c->read_cap) {
                            char *new_buf = malloc(new_cap);
                            if (!new_buf) { close_conn(w, c); break; }
                            memcpy(new_buf, c->read_buf, c->read_pos);
                            if (c->read_buf != c->inline_read_buf) free(c->read_buf);
                            c->read_buf = new_buf;
                            c->read_cap = new_cap;
                        } else {
                            close_conn(w, c);
                            break;
                        }
                    }

                    ssize_t n = 0;
                    if (c->is_tls) {
                        int ret = SSL_read(c->ssl, c->read_buf + c->read_pos, (int)(c->read_cap - c->read_pos));
                        if (ret <= 0) {
                            int err = SSL_get_error(c->ssl, ret);
                            if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE) {
                                break;
                            }
                            close_conn(w, c);
                            break;
                        }
                        n = ret;
                    } else {
                        n = recv(c->fd, c->read_buf + c->read_pos, c->read_cap - c->read_pos, 0);
                        if (n < 0) {
                            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                                break;
                            }
                            close_conn(w, c);
                            break;
                        }
                        if (n == 0) {
                            close_conn(w, c);
                            break;
                        }
                    }
                    c->read_pos += (size_t)n;
                }

                if (c->fd >= 0 && c->read_pos > 0) {
                    process_requests(w, c);
                }
            }
        }
    }

    close(w->epoll_fd);
    close(w->listen_h1_fd);
    if (w->listen_tls_fd >= 0) close(w->listen_tls_fd);
    compress_worker_destroy(&w->compress);
    timer_heap_destroy(&w->timers);

    conn_t *curr = w->free_conns;
    while (curr) {
        conn_t *next = curr->next_free;
        if (curr->read_buf != curr->inline_read_buf) {
            free(curr->read_buf);
        }
        if (curr->pending_write) {
            free(curr->pending_write);
        }
        free(curr);
        curr = next;
    }
    w->free_conns = NULL;

    return NULL;
}

static int create_listen_socket(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
    set_sock_opts(fd);

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons(port),
        .sin_addr.s_addr = INADDR_ANY
    };

    if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }

    if (listen(fd, 65535) < 0) {
        close(fd);
        return -1;
    }

    return fd;
}

int main(void) {
    signal(SIGINT, handle_sig);
    signal(SIGTERM, handle_sig);
    signal(SIGPIPE, SIG_IGN);

    cpu_set_t cs;
    int allowed_cpus[MAX_WORKERS];
    int num_allowed = 0;
    if (sched_getaffinity(0, sizeof(cs), &cs) == 0) {
        for (int i = 0; i < CPU_SETSIZE && num_allowed < MAX_WORKERS; i++) {
            if (CPU_ISSET(i, &cs)) {
                allowed_cpus[num_allowed++] = i;
            }
        }
    }
    if (num_allowed == 0) {
        long ncpu = sysconf(_SC_NPROCESSORS_ONLN);
        if (ncpu <= 0) ncpu = 1;
        if (ncpu > MAX_WORKERS) ncpu = MAX_WORKERS;
        for (int i = 0; i < ncpu; i++) allowed_cpus[i] = i;
        num_allowed = (int)ncpu;
    }
    g_num_workers = num_allowed;

    const char *dataset_path = getenv("DATASET_PATH");
    if (!dataset_path) dataset_path = "/data/dataset.json";
    if (!dataset_load(dataset_path)) {
        dataset_load("./data/dataset.json");
    }

    const char *static_root = getenv("STATIC_ROOT");
    if (!static_root) static_root = "/data/static";
    static_files_init(static_root);

    const char *cert_file = getenv("TLS_CERT");
    if (!cert_file) cert_file = "/certs/server.crt";
    const char *key_file = getenv("TLS_KEY");
    if (!key_file) key_file = "/certs/server.key";

    SSL_CTX *shared_ssl_ctx = tls_init_server_ctx(cert_file, key_file);
    if (!shared_ssl_ctx) {
        shared_ssl_ctx = tls_init_server_ctx("./certs/server.crt", "./certs/server.key");
    }

    g_workers = calloc((size_t)g_num_workers, sizeof(worker_t));
    if (!g_workers) {
        perror("calloc g_workers");
        return 1;
    }

    for (int i = 0; i < g_num_workers; i++) {
        worker_t *w = &g_workers[i];
        w->id = i;
        w->cpu_id = allowed_cpus[i];
        w->ssl_ctx = shared_ssl_ctx;

        router_init(&w->router);
        router_add(&w->router, HTTP_METHOD_GET, "/baseline11", baseline_handler);
        router_add(&w->router, HTTP_METHOD_POST, "/baseline11", baseline_handler);
        router_add(&w->router, HTTP_METHOD_GET, "/pipeline", pipeline_handler);
        router_add(&w->router, HTTP_METHOD_GET, "/delay/:ms", delay_handler);
        router_add(&w->router, HTTP_METHOD_GET, "/json/:count", json_handler);
        router_add(&w->router, HTTP_METHOD_POST, "/echo", echo_handler);
        router_add(&w->router, HTTP_METHOD_GET, "/static/", static_file_handler);

        compress_worker_init(&w->compress);
        timer_heap_init(&w->timers, 4096);
        w->free_conns = NULL;

        for (int k = 0; k < 128; k++) {
            conn_t *c = calloc(1, sizeof(conn_t));
            if (c) {
                c->read_buf = c->inline_read_buf;
                c->read_cap = sizeof(c->inline_read_buf);
                c->fd = -1;
                c->next_free = w->free_conns;
                w->free_conns = c;
            }
        }

        w->epoll_fd = epoll_create1(EPOLL_CLOEXEC);
        w->listen_h1_fd = create_listen_socket(8080);
        w->token_h1 = 1;
        struct epoll_event ev1 = { .events = EPOLLIN, .data.ptr = &w->token_h1 };
        epoll_ctl(w->epoll_fd, EPOLL_CTL_ADD, w->listen_h1_fd, &ev1);

        if (w->ssl_ctx) {
            w->listen_tls_fd = create_listen_socket(8081);
            if (w->listen_tls_fd >= 0) {
                w->token_tls = 2;
                struct epoll_event ev2 = { .events = EPOLLIN, .data.ptr = &w->token_tls };
                epoll_ctl(w->epoll_fd, EPOLL_CTL_ADD, w->listen_tls_fd, &ev2);
            }
        } else {
            w->listen_tls_fd = -1;
        }

        pthread_create(&w->thread, NULL, worker_main, w);
    }

    for (int i = 0; i < g_num_workers; i++) {
        pthread_join(g_workers[i].thread, NULL);
    }

    if (shared_ssl_ctx) {
        tls_free_server_ctx(shared_ssl_ctx);
    }

    free(g_workers);
    return 0;
}
