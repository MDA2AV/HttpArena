#include "common.h"
#include "http.h"
#include "router.h"
#include "dataset.h"
#include "timer.h"
#include "tls.h"
#include "static_files.h"

typedef struct {
    int         fd;
    uint32_t    gen;
    bool        is_tls;
    SSL        *ssl;
    bool        tls_handshake_done;

    char        read_buf[READ_BUF_SIZE];
    size_t      read_pos;

    char        write_buf[WRITE_BUF_SIZE];
    size_t      write_pos;
    size_t      write_sent;

    char        chunk_buf[128 * 1024];
    char        scratch[64];

    bool        parked_in_timer;
    uint64_t    timer_expire_ms;
    int64_t     timer_val_ms;

    bool        keep_alive;
    bool        closing;
} conn_t;

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
    conn_t           *conns;
} worker_t;

static volatile bool g_running = true;
static int           g_num_workers = 1;
static worker_t      g_workers[MAX_WORKERS];
static __thread worker_t *t_worker = NULL;

static void handle_sig(int sig) {
    (void)sig;
    g_running = false;
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
    c->timer_expire_ms = clock_monotonic_ms() + (uint64_t)ms;
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

static void close_conn(worker_t *w, conn_t *c) {
    if (c->fd < 0) return;
    epoll_ctl(w->epoll_fd, EPOLL_CTL_DEL, c->fd, NULL);
    if (c->is_tls && c->ssl) {
        SSL_shutdown(c->ssl);
        SSL_free(c->ssl);
        c->ssl = NULL;
    }
    close(c->fd);
    c->fd = -1;
    c->read_pos = 0;
    c->write_pos = 0;
    c->write_sent = 0;
    c->parked_in_timer = false;
    c->closing = false;
    c->gen++;
}

static bool flush_write_buf(worker_t *w, conn_t *c) {
    while (c->write_sent < c->write_pos) {
        size_t remaining = c->write_pos - c->write_sent;
        ssize_t n = 0;
        if (c->is_tls) {
            int ret = SSL_write(c->ssl, c->write_buf + c->write_sent, (int)remaining);
            if (ret <= 0) {
                int err = SSL_get_error(c->ssl, ret);
                if (err == SSL_ERROR_WANT_WRITE || err == SSL_ERROR_WANT_READ) {
                    struct epoll_event ev = {
                        .events = EPOLLIN | EPOLLOUT | EPOLLET | EPOLLRDHUP | EPOLLHUP | EPOLLERR,
                        .data.fd = c->fd
                    };
                    epoll_ctl(w->epoll_fd, EPOLL_CTL_MOD, c->fd, &ev);
                    return false;
                }
                close_conn(w, c);
                return false;
            }
            n = ret;
        } else {
            n = send(c->fd, c->write_buf + c->write_sent, remaining, MSG_NOSIGNAL);
            if (n < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    struct epoll_event ev = {
                        .events = EPOLLIN | EPOLLOUT | EPOLLET | EPOLLRDHUP | EPOLLHUP | EPOLLERR,
                        .data.fd = c->fd
                    };
                    epoll_ctl(w->epoll_fd, EPOLL_CTL_MOD, c->fd, &ev);
                    return false;
                }
                close_conn(w, c);
                return false;
            }
        }
        c->write_sent += (size_t)n;
    }

    c->write_pos = 0;
    c->write_sent = 0;

    struct epoll_event ev = {
        .events = EPOLLIN | EPOLLET | EPOLLRDHUP | EPOLLHUP | EPOLLERR,
        .data.fd = c->fd
    };
    epoll_ctl(w->epoll_fd, EPOLL_CTL_MOD, c->fd, &ev);

    if (c->closing || !c->keep_alive) {
        close_conn(w, c);
        return false;
    }

    return true;
}

static void process_requests(worker_t *w, conn_t *c) {
    while (c->read_pos > 0 && !c->parked_in_timer && !c->closing) {
        request_t req;
        size_t consumed = 0;
        int rc = parse_http_request(c->read_buf, c->read_pos, &req, c->chunk_buf, sizeof(c->chunk_buf), &consumed);

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
            timer_heap_push(&w->timers, c->timer_expire_ms, c->fd, c->gen, c->timer_val_ms);
            if (consumed < c->read_pos) {
                memmove(c->read_buf, c->read_buf + consumed, c->read_pos - consumed);
                c->read_pos -= consumed;
            } else {
                c->read_pos = 0;
            }
            break;
        }

        size_t remaining_space = sizeof(c->write_buf) - c->write_pos;
        size_t written = res_serialize(&res, c->write_buf + c->write_pos, remaining_space);
        if (res.body_needs_free && res.body) {
            free((void*)res.body);
        }

        if (written == 0) {
            close_conn(w, c);
            return;
        }

        c->write_pos += written;

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

    if (c->write_pos > c->write_sent) {
        flush_write_buf(w, c);
    }
}

static void handle_timer_expiration(worker_t *w, timer_entry_t *te) {
    if (te->conn_fd < 0 || te->conn_fd >= MAX_CONNS_PER_WORKER) return;
    conn_t *c = &w->conns[te->conn_fd];
    if (c->fd != te->conn_fd || c->gen != te->conn_gen || !c->parked_in_timer) return;

    c->parked_in_timer = false;

    response_t res;
    res_init(&res, c->keep_alive);
    char buf[24];
    size_t len = format_i64(buf, te->delay_ms);
    res_set_text(&res, buf, len);

    size_t remaining_space = sizeof(c->write_buf) - c->write_pos;
    size_t written = res_serialize(&res, c->write_buf + c->write_pos, remaining_space);
    if (written > 0) {
        c->write_pos += written;
        flush_write_buf(w, c);
    } else {
        close_conn(w, c);
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
        uint64_t now_ms = clock_monotonic_ms();

        timer_entry_t te;
        while (timer_heap_peek(&w->timers, &te)) {
            if (te.expire_at_ms <= now_ms) {
                timer_heap_pop(&w->timers, &te);
                handle_timer_expiration(w, &te);
            } else {
                break;
            }
        }

        int timeout = timer_heap_next_timeout_ms(&w->timers, now_ms);
        int nfds = epoll_wait(w->epoll_fd, events, MAX_EVENTS, timeout);
        if (nfds < 0) {
            if (errno == EINTR) continue;
            break;
        }

        for (int i = 0; i < nfds; i++) {
            int fd = events[i].data.fd;
            uint32_t evs = events[i].events;

            if (fd == w->listen_h1_fd) {
                while (true) {
                    int cfd = accept4(w->listen_h1_fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
                    if (cfd < 0) break;
                    if (cfd >= MAX_CONNS_PER_WORKER) { close(cfd); continue; }

                    set_sock_opts(cfd);
                    conn_t *c = &w->conns[cfd];
                    c->fd = cfd;
                    c->is_tls = false;
                    c->ssl = NULL;
                    c->read_pos = 0;
                    c->write_pos = 0;
                    c->write_sent = 0;
                    c->parked_in_timer = false;
                    c->closing = false;

                    struct epoll_event ev = {
                        .events = EPOLLIN | EPOLLET | EPOLLRDHUP | EPOLLHUP | EPOLLERR,
                        .data.fd = cfd
                    };
                    epoll_ctl(w->epoll_fd, EPOLL_CTL_ADD, cfd, &ev);
                }
                continue;
            }

            if (w->listen_tls_fd >= 0 && fd == w->listen_tls_fd) {
                while (true) {
                    int cfd = accept4(w->listen_tls_fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
                    if (cfd < 0) break;
                    if (cfd >= MAX_CONNS_PER_WORKER) { close(cfd); continue; }

                    set_sock_opts(cfd);
                    SSL *ssl = SSL_new(w->ssl_ctx);
                    if (!ssl) { close(cfd); continue; }
                    SSL_set_fd(ssl, cfd);
                    SSL_set_accept_state(ssl);

                    conn_t *c = &w->conns[cfd];
                    c->fd = cfd;
                    c->is_tls = true;
                    c->ssl = ssl;
                    c->tls_handshake_done = false;
                    c->read_pos = 0;
                    c->write_pos = 0;
                    c->write_sent = 0;
                    c->parked_in_timer = false;
                    c->closing = false;

                    struct epoll_event ev = {
                        .events = EPOLLIN | EPOLLOUT | EPOLLET | EPOLLRDHUP | EPOLLHUP | EPOLLERR,
                        .data.fd = cfd
                    };
                    epoll_ctl(w->epoll_fd, EPOLL_CTL_ADD, cfd, &ev);
                }
                continue;
            }

            conn_t *c = &w->conns[fd];
            if (c->fd != fd) continue;

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
                    .data.fd = fd
                };
                epoll_ctl(w->epoll_fd, EPOLL_CTL_MOD, fd, &ev);
            }

            if (evs & EPOLLOUT) {
                if (c->write_pos > c->write_sent) {
                    flush_write_buf(w, c);
                }
            }

            if (evs & EPOLLIN) {
                while (true) {
                    size_t rem = sizeof(c->read_buf) - c->read_pos;
                    if (rem == 0) {
                        close_conn(w, c);
                        break;
                    }
                    ssize_t n = 0;
                    if (c->is_tls) {
                        int r = SSL_read(c->ssl, c->read_buf + c->read_pos, (int)rem);
                        if (r <= 0) {
                            int err = SSL_get_error(c->ssl, r);
                            if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE) {
                                break;
                            }
                            close_conn(w, c);
                            break;
                        }
                        n = r;
                    } else {
                        n = recv(c->fd, c->read_buf + c->read_pos, rem, 0);
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

                if (c->fd >= 0) {
                    process_requests(w, c);
                }
            }
        }
    }

    return NULL;
}

static int create_listen_socket(int port) {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;

    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    setsockopt(fd, IPPROTO_TCP, TCP_QUICKACK, &one, sizeof(one));

    #ifdef TCP_DEFER_ACCEPT
    int timeout = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_DEFER_ACCEPT, &timeout, sizeof(timeout));
    #endif

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons((uint16_t)port),
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

    long ncpu = sysconf(_SC_NPROCESSORS_ONLN);
    if (ncpu <= 0) ncpu = 1;
    if (ncpu > MAX_WORKERS) ncpu = MAX_WORKERS;
    g_num_workers = (int)ncpu;

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

    for (int i = 0; i < g_num_workers; i++) {
        worker_t *w = &g_workers[i];
        w->id = i;
        w->cpu_id = i;
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
        w->conns = calloc(MAX_CONNS_PER_WORKER, sizeof(conn_t));

        w->epoll_fd = epoll_create1(EPOLL_CLOEXEC);
        w->listen_h1_fd = create_listen_socket(8080);
        struct epoll_event ev1 = { .events = EPOLLIN, .data.fd = w->listen_h1_fd };
        epoll_ctl(w->epoll_fd, EPOLL_CTL_ADD, w->listen_h1_fd, &ev1);

        if (w->ssl_ctx) {
            w->listen_tls_fd = create_listen_socket(8081);
            if (w->listen_tls_fd >= 0) {
                struct epoll_event ev2 = { .events = EPOLLIN, .data.fd = w->listen_tls_fd };
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

    return 0;
}
