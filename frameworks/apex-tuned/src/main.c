#include "server.h"
#include "tls.h"
#include "static_files.h"
#include "h2.h"

static volatile bool g_running = true;
static int           g_num_workers = 1;
static worker_t     *g_workers = NULL;
static __thread worker_t *t_worker = NULL;

static void handle_sig(int sig) {
    (void)sig;
    _exit(0);
}

static inline void conn_list_insert_tail(worker_t *w, conn_t *c) {
    c->active_prev = w->active_tail;
    c->active_next = NULL;
    if (w->active_tail) {
        w->active_tail->active_next = c;
    } else {
        w->active_head = c;
    }
    w->active_tail = c;
}

static inline void conn_list_remove(worker_t *w, conn_t *c) {
    if (c->active_prev || c->active_next || w->active_head == c || w->active_tail == c) {
        if (c->active_prev) {
            c->active_prev->active_next = c->active_next;
        } else if (w->active_head == c) {
            w->active_head = c->active_next;
        }
        if (c->active_next) {
            c->active_next->active_prev = c->active_prev;
        } else if (w->active_tail == c) {
            w->active_tail = c->active_prev;
        }
        c->active_prev = NULL;
        c->active_next = NULL;
    }
}

static inline void conn_touch(worker_t *w, conn_t *c, uint64_t now_ms) {
    c->last_active_ms = now_ms;
    if (w->active_tail == c) return;
    conn_list_remove(w, c);
    conn_list_insert_tail(w, c);
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
    c->is_h2 = false;
    c->h2 = NULL;
    c->parked_in_timer = false;
    c->keep_alive = true;
    c->closing = false;
    c->next_free = NULL;
    c->active_prev = NULL;
    c->active_next = NULL;
    c->last_active_ms = clock_monotonic_ms();
    conn_list_insert_tail(w, c);
    return c;
}

void close_conn(worker_t *w, conn_t *c) {
    conn_list_remove(w, c);
    if (c->is_h2) {
        h2_conn_free(c);
        c->is_h2 = false;
    }
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
        str_view_t rp = req->route_params[0];
        if (rp.len == 2 && rp.ptr[0] == '1' && rp.ptr[1] == '0') {
            ms = 10;
        } else {
            parse_i64(rp.ptr, rp.len, &ms);
        }
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
            n = send(c->fd, c->pending_write + c->pending_write_sent, remaining, MSG_NOSIGNAL | MSG_DONTWAIT);
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

void flush_data(worker_t *w, conn_t *c, const char *data, size_t len) {
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
            n = send(c->fd, data + sent, len - sent, MSG_NOSIGNAL | MSG_DONTWAIT);
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

static inline int64_t fast_parse_int(const char *p, size_t len) {
    const char *end = p + len;
    while (p < end && (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')) p++;
    int neg = 0;
    if (p < end && *p == '-') { neg = 1; p++; }
    int64_t n = 0;
    while (p < end && *p >= '0' && *p <= '9') {
        n = n * 10 + (*p - '0');
        p++;
    }
    return neg ? -n : n;
}

static inline int64_t fast_sum_query(const char *p, size_t len) {
    const char *end = p + len;
    int64_t sum = 0;
    while (p < end) {
        const char *eq = memchr(p, '=', (size_t)(end - p));
        if (!eq) break;
        const char *v = eq + 1;
        const char *amp = memchr(v, '&', (size_t)(end - v));
        const char *ve = amp ? amp : end;
        while (v < ve && (*v == ' ' || *v == '\t')) v++;
        int neg = 0;
        if (v < ve && *v == '-') { neg = 1; v++; }
        int64_t n = 0;
        while (v < ve && *v >= '0' && *v <= '9') {
            n = n * 10 + (*v - '0');
            v++;
        }
        sum += neg ? -n : n;
        p = amp ? amp + 1 : end;
    }
    return sum;
}

static void process_requests(worker_t *w, conn_t *c) {
    size_t write_pos = 0;
    size_t read_offset = 0;

    while (c->read_pos > read_offset && !c->parked_in_timer && !c->closing) {
        request_t req;
        size_t consumed = 0;
        int rc = parse_http_request(c->read_buf + read_offset, c->read_pos - read_offset, &req, w->chunk_buf, sizeof(w->chunk_buf), &consumed);

        if (rc == 0) {
            break;
        }
        if (rc < 0) {
            close_conn(w, c);
            return;
        }

        c->keep_alive = req.keep_alive;

        // ── Ultra-fast path for /pipeline ──
        if (__builtin_expect(req.path.len == 9 && memcmp(req.path.ptr, "/pipeline", 9) == 0, 0)) {
            if (sizeof(w->write_buf) - write_pos < 128) {
                if (write_pos > 0) {
                    flush_data(w, c, w->write_buf, write_pos);
                    write_pos = 0;
                }
            }
            char *p = w->write_buf + write_pos;
            if (__builtin_expect(c->keep_alive, 1)) {
                static const char pipeline_res[] = 
                    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: keep-alive\r\nContent-Length: 2\r\n\r\nok";
                memcpy(p, pipeline_res, sizeof(pipeline_res) - 1);
                p += sizeof(pipeline_res) - 1;
            } else {
                static const char pipeline_res_close[] = 
                    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: 2\r\n\r\nok";
                memcpy(p, pipeline_res_close, sizeof(pipeline_res_close) - 1);
                p += sizeof(pipeline_res_close) - 1;
                c->closing = true;
            }
            write_pos = (size_t)(p - w->write_buf);
            read_offset += consumed;
            continue;
        }

        // ── Ultra-fast path for /baseline11 ──
        if (__builtin_expect(req.path.len == 11 && memcmp(req.path.ptr, "/baseline11", 11) == 0, 0)) {
            int64_t sum = req.query.len > 0 ? fast_sum_query(req.query.ptr, req.query.len) : 0;
            if (req.method == HTTP_METHOD_POST && req.body.len > 0) {
                sum += fast_parse_int(req.body.ptr, req.body.len);
            }

            char num_buf[32];
            size_t num_len = (size_t)format_i64(num_buf, sum);

            if (sizeof(w->write_buf) - write_pos < 128) {
                if (write_pos > 0) {
                    flush_data(w, c, w->write_buf, write_pos);
                    write_pos = 0;
                }
            }

            char *p = w->write_buf + write_pos;
            if (__builtin_expect(c->keep_alive, 1)) {
                static const char h_ka[] = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: keep-alive\r\nContent-Length: ";
                memcpy(p, h_ka, sizeof(h_ka) - 1);
                p += sizeof(h_ka) - 1;
                p += format_i64(p, (int64_t)num_len);
                *p++ = '\r'; *p++ = '\n';
                *p++ = '\r'; *p++ = '\n';
                memcpy(p, num_buf, num_len);
                p += num_len;
            } else {
                static const char h_cl[] = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: ";
                memcpy(p, h_cl, sizeof(h_cl) - 1);
                p += sizeof(h_cl) - 1;
                p += format_i64(p, (int64_t)num_len);
                *p++ = '\r'; *p++ = '\n';
                *p++ = '\r'; *p++ = '\n';
                memcpy(p, num_buf, num_len);
                p += num_len;
                c->closing = true;
            }

            write_pos = (size_t)(p - w->write_buf);
            read_offset += consumed;
            continue;
        }

        // ── Ultra-fast path for /baseline2 ──
        if (__builtin_expect(req.path.len == 10 && memcmp(req.path.ptr, "/baseline2", 10) == 0, 0)) {
            int64_t sum = req.query.len > 0 ? fast_sum_query(req.query.ptr, req.query.len) : 0;
            char num_buf[32];
            size_t num_len = (size_t)format_i64(num_buf, sum);

            if (sizeof(w->write_buf) - write_pos < 128) {
                if (write_pos > 0) {
                    flush_data(w, c, w->write_buf, write_pos);
                    write_pos = 0;
                }
            }

            char *p = w->write_buf + write_pos;
            if (__builtin_expect(c->keep_alive, 1)) {
                static const char h_ka[] = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: keep-alive\r\nContent-Length: ";
                memcpy(p, h_ka, sizeof(h_ka) - 1);
                p += sizeof(h_ka) - 1;
                p += format_i64(p, (int64_t)num_len);
                *p++ = '\r'; *p++ = '\n';
                *p++ = '\r'; *p++ = '\n';
                memcpy(p, num_buf, num_len);
                p += num_len;
            } else {
                static const char h_cl[] = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: ";
                memcpy(p, h_cl, sizeof(h_cl) - 1);
                p += sizeof(h_cl) - 1;
                p += format_i64(p, (int64_t)num_len);
                *p++ = '\r'; *p++ = '\n';
                *p++ = '\r'; *p++ = '\n';
                memcpy(p, num_buf, num_len);
                p += num_len;
                c->closing = true;
            }

            write_pos = (size_t)(p - w->write_buf);
            read_offset += consumed;
            continue;
        }

        response_t res;
        res_init(&res, c->keep_alive);

        bool async_parked = false;
        if (!router_dispatch(&w->router, &req, &res, c, &async_parked)) {
            res_set_status(&res, 404);
            res_set_text(&res, "Not Found", 9);
        }

        if (async_parked) {
            timer_heap_push(&w->timers, c->timer_expire_us, c, c->gen, c->timer_val_ms);
            read_offset += consumed;
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
        read_offset += consumed;

        if (!c->keep_alive) {
            c->closing = true;
        }
    }

    if (read_offset > 0) {
        if (read_offset < c->read_pos) {
            memmove(c->read_buf, c->read_buf + read_offset, c->read_pos - read_offset);
            c->read_pos -= read_offset;
        } else {
            c->read_pos = 0;
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

    if (__builtin_expect(delay_ms == 10 && c->keep_alive, 1)) {
        ssize_t n = send(c->fd, res_delay_10, res_delay_10_len, MSG_NOSIGNAL | MSG_DONTWAIT);
        if (__builtin_expect(n == (ssize_t)res_delay_10_len, 1)) {
        } else if (n > 0) {
            flush_data(w, c, res_delay_10 + n, res_delay_10_len - (size_t)n);
        } else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            flush_data(w, c, res_delay_10, res_delay_10_len);
        } else {
            close_conn(w, c);
            return;
        }
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

#if defined(__linux__) && defined(PR_SET_TIMERSLACK)
    prctl(PR_SET_TIMERSLACK, 1UL, 0, 0, 0);
#endif

    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(w->cpu_id, &cpuset);
    pthread_setaffinity_np(pthread_self(), sizeof(cpuset), &cpuset);

    struct epoll_event events[MAX_EVENTS];

    while (g_running) {
        uint64_t now_us = clock_monotonic_us();

        if (w->timers.count > 0) {
            timer_entry_t te;
            while (timer_heap_peek(&w->timers, &te)) {
                if (te.expire_at_us > now_us) break;
                timer_heap_pop(&w->timers, &te);
                conn_t *c = (conn_t*)te.conn_ptr;
                if (c && c->gen == te.conn_gen && c->parked_in_timer) {
                    handle_timer_expiration(w, c, te.delay_ms);
                }
            }
        }

        int64_t timeout_us = timer_heap_next_timeout_us(&w->timers, now_us);
        if (timeout_us < 0 || timeout_us > 1000000) {
            timeout_us = 1000000;
        }
        int nfds = 0;

        if (timeout_us <= 350) {
            uint64_t target_us = now_us + (uint64_t)timeout_us;
            while (true) {
                nfds = epoll_wait(w->epoll_fd, events, MAX_EVENTS, 0);
                if (nfds != 0) break;
                now_us = clock_monotonic_us();
                if (now_us >= target_us) break;
                for (int spin = 0; spin < 16; spin++) {
#if defined(__x86_64__) || defined(_M_X64)
                    __builtin_ia32_pause();
#elif defined(__aarch64__)
                    asm volatile("yield" ::: "memory");
#endif
                }
            }
        } else {
            int64_t sleep_us = timeout_us - 250;
#if defined(__linux__)
            struct timespec ts = {
                .tv_sec = (time_t)(sleep_us / 1000000),
                .tv_nsec = (long)((sleep_us % 1000000) * 1000)
            };
            nfds = epoll_pwait2(w->epoll_fd, events, MAX_EVENTS, &ts, NULL);
            if (nfds < 0 && errno == ENOSYS) {
                int timeout_ms = (int)(sleep_us / 1000);
                if (timeout_ms < 1) timeout_ms = 1;
                nfds = epoll_wait(w->epoll_fd, events, MAX_EVENTS, timeout_ms);
            }
#else
            int timeout_ms = (int)(sleep_us / 1000);
            if (timeout_ms < 1) timeout_ms = 1;
            nfds = epoll_wait(w->epoll_fd, events, MAX_EVENTS, timeout_ms);
#endif
        }

        if (nfds < 0) {
            if (errno == EINTR) continue;
            break;
        }

        uint64_t now_ms = clock_monotonic_ms();

        // Reap connections idle for >= 15 seconds
        while (w->active_head) {
            conn_t *oldest = w->active_head;
            if (now_ms - oldest->last_active_ms < 15000) {
                break;
            }
            if (oldest->parked_in_timer) {
                oldest->last_active_ms = now_ms;
                if (w->active_head != w->active_tail) {
                    conn_list_remove(w, oldest);
                    conn_list_insert_tail(w, oldest);
                    continue;
                }
                break;
            }
            close_conn(w, oldest);
        }

#if defined(__linux__)
        if (w->id == 0 && (now_ms - w->last_trim_ms >= 5000)) {
            w->last_trim_ms = now_ms;
            malloc_trim(0);
        }
#endif

        if (w->timers.count > 0) {
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

            if (w->listen_h2c_fd >= 0 && ptr == &w->token_h2c) {
                while (true) {
                    int cfd = accept4(w->listen_h2c_fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
                    if (cfd < 0) break;

                    set_sock_opts(cfd);
                    conn_t *c = alloc_conn(w, cfd, false, NULL);
                    if (!c) { close(cfd); continue; }

                    c->is_h2 = true;
                    if (!h2_conn_init(c, w)) {
                        close_conn(w, c);
                        continue;
                    }

                    struct epoll_event ev = {
                        .events = EPOLLIN | EPOLLET | EPOLLRDHUP | EPOLLHUP | EPOLLERR,
                        .data.ptr = c
                    };
                    epoll_ctl(w->epoll_fd, EPOLL_CTL_ADD, cfd, &ev);
                }
                continue;
            }

            if (w->listen_h2_fd >= 0 && ptr == &w->token_h2) {
                while (true) {
                    int cfd = accept4(w->listen_h2_fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
                    if (cfd < 0) break;

                    set_sock_opts(cfd);
                    SSL *ssl = SSL_new(w->ssl_ctx_h2);
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

            conn_touch(w, c, now_ms);

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

                const unsigned char *alpn = NULL;
                unsigned int alpn_len = 0;
                SSL_get0_alpn_selected(c->ssl, &alpn, &alpn_len);
                if (alpn && alpn_len == 2 && memcmp(alpn, "h2", 2) == 0) {
                    c->is_h2 = true;
                    if (!h2_conn_init(c, w)) {
                        close_conn(w, c);
                        continue;
                    }
                }

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
                if (c->is_h2) {
                    char h2_in[65536];
                    while (true) {
                        ssize_t n = 0;
                        if (c->is_tls) {
                            int ret = SSL_read(c->ssl, h2_in, sizeof(h2_in));
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
                            n = recv(c->fd, h2_in, sizeof(h2_in), MSG_DONTWAIT);
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
                        if (!h2_conn_process(c, w, h2_in, (size_t)n)) {
                            close_conn(w, c);
                            break;
                        }
                    }
                    continue;
                }

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

                    size_t avail = c->read_cap - c->read_pos;
                    ssize_t n = 0;
                    if (c->is_tls) {
                        int ret = SSL_read(c->ssl, c->read_buf + c->read_pos, (int)avail);
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
                        n = recv(c->fd, c->read_buf + c->read_pos, avail, MSG_DONTWAIT);
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
                    if (c->read_pos >= 4) {
                        const char *hdr_end = memmem(c->read_buf, c->read_pos, "\r\n\r\n", 4);
                        if (hdr_end) {
                            size_t hdr_len = (size_t)(hdr_end - c->read_buf) + 4;
                            if (c->read_buf[0] == 'G' || c->read_buf[0] == 'H') {
                                break;
                            }
                            const char *cl_pos = memmem(c->read_buf, hdr_len, "Content-Length: ", 16);
                            if (!cl_pos) {
                                cl_pos = memmem(c->read_buf, hdr_len, "content-length: ", 16);
                            }
                            if (cl_pos) {
                                int64_t cl = 0;
                                if (parse_i64(cl_pos + 16, (size_t)(hdr_end - (cl_pos + 16)), &cl) && cl >= 0) {
                                    if (c->read_pos >= hdr_len + (size_t)cl) {
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }

                if (c->fd >= 0 && c->read_pos > 0) {
                    process_requests(w, c);
                }
                if (c->is_tls) {
                    while (c->fd >= 0 && !c->closing && SSL_pending(c->ssl) > 0) {
                        size_t avail = c->read_cap - c->read_pos;
                        if (avail == 0) break;
                        int ret = SSL_read(c->ssl, c->read_buf + c->read_pos, (int)avail);
                        if (ret <= 0) break;
                        c->read_pos += (size_t)ret;
                        process_requests(w, c);
                    }
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
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;

    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
#if defined(TCP_DEFER_ACCEPT)
    int defer = 5;
    setsockopt(fd, IPPROTO_TCP, TCP_DEFER_ACCEPT, &defer, sizeof(defer));
#endif
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

    SSL_CTX *shared_ssl_ctx = tls_init_server_ctx(cert_file, key_file, false);
    if (!shared_ssl_ctx) {
        shared_ssl_ctx = tls_init_server_ctx("./certs/server.crt", "./certs/server.key", false);
    }

    SSL_CTX *shared_ssl_ctx_h2 = tls_init_server_ctx(cert_file, key_file, true);
    if (!shared_ssl_ctx_h2) {
        shared_ssl_ctx_h2 = tls_init_server_ctx("./certs/server.crt", "./certs/server.key", true);
    }

    g_workers = calloc((size_t)g_num_workers, sizeof(worker_t));
    if (!g_workers) {
        perror("calloc g_workers");
        return 1;
    }

    int port_h1 = 8080;
    const char *port_env = getenv("PORT");
    if (port_env) {
        int p = atoi(port_env);
        if (p > 0) port_h1 = p;
    }

    int port_tls = 8081;
    const char *tls_port_env = getenv("TLS_PORT");
    if (tls_port_env) {
        int p = atoi(tls_port_env);
        if (p > 0) port_tls = p;
    }

    int port_h2c = 8082;
    const char *h2c_port_env = getenv("H2C_PORT");
    if (h2c_port_env) {
        int p = atoi(h2c_port_env);
        if (p > 0) port_h2c = p;
    }

    int port_h2 = 8443;
    const char *h2_port_env = getenv("H2_PORT");
    if (!h2_port_env) h2_port_env = getenv("H2PORT");
    if (h2_port_env) {
        int p = atoi(h2_port_env);
        if (p > 0) port_h2 = p;
    }

    for (int i = 0; i < g_num_workers; i++) {
        worker_t *w = &g_workers[i];
        w->id = i;
        w->cpu_id = allowed_cpus[i];
        w->ssl_ctx = shared_ssl_ctx;
        w->ssl_ctx_h2 = shared_ssl_ctx_h2;

        router_init(&w->router);
        router_add(&w->router, HTTP_METHOD_GET, "/", pipeline_handler);
        router_add(&w->router, HTTP_METHOD_GET, "/baseline11", baseline_handler);
        router_add(&w->router, HTTP_METHOD_POST, "/baseline11", baseline_handler);
        router_add(&w->router, HTTP_METHOD_GET, "/pipeline", pipeline_handler);
        router_add(&w->router, HTTP_METHOD_GET, "/delay/:ms", delay_handler);
        router_add(&w->router, HTTP_METHOD_GET, "/json/:count", json_handler);
        router_add(&w->router, HTTP_METHOD_POST, "/echo", echo_handler);
        router_add(&w->router, HTTP_METHOD_GET, "/static/", static_file_handler);
        router_add(&w->router, HTTP_METHOD_HEAD, "/static/", static_file_handler);
        router_add(&w->router, HTTP_METHOD_HEAD, "/", pipeline_handler);

        compress_worker_init(&w->compress);
        timer_heap_init(&w->timers, 16384);
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
        w->listen_h1_fd = create_listen_socket(port_h1);
        w->token_h1 = 1;
        struct epoll_event ev1 = { .events = EPOLLIN, .data.ptr = &w->token_h1 };
        epoll_ctl(w->epoll_fd, EPOLL_CTL_ADD, w->listen_h1_fd, &ev1);

        if (w->ssl_ctx) {
            w->listen_tls_fd = create_listen_socket(port_tls);
            if (w->listen_tls_fd >= 0) {
                w->token_tls = 2;
                struct epoll_event ev2 = { .events = EPOLLIN, .data.ptr = &w->token_tls };
                epoll_ctl(w->epoll_fd, EPOLL_CTL_ADD, w->listen_tls_fd, &ev2);
            }
        } else {
            w->listen_tls_fd = -1;
        }

        w->listen_h2c_fd = create_listen_socket(port_h2c);
        if (w->listen_h2c_fd >= 0) {
            w->token_h2c = 3;
            struct epoll_event ev3 = { .events = EPOLLIN, .data.ptr = &w->token_h2c };
            epoll_ctl(w->epoll_fd, EPOLL_CTL_ADD, w->listen_h2c_fd, &ev3);
        }

        if (w->ssl_ctx_h2) {
            w->listen_h2_fd = create_listen_socket(port_h2);
            if (w->listen_h2_fd >= 0) {
                w->token_h2 = 4;
                struct epoll_event ev4 = { .events = EPOLLIN, .data.ptr = &w->token_h2 };
                epoll_ctl(w->epoll_fd, EPOLL_CTL_ADD, w->listen_h2_fd, &ev4);
            }
        } else {
            w->listen_h2_fd = -1;
        }

        pthread_create(&w->thread, NULL, worker_main, w);
    }

    printf("[apex] Server listening on port %d (TLS: %d, H2C: %d, H2: %d) with %d workers\n",
           port_h1, shared_ssl_ctx ? port_tls : -1, port_h2c, shared_ssl_ctx_h2 ? port_h2 : -1, g_num_workers);
    fflush(stdout);

    for (int i = 0; i < g_num_workers; i++) {
        pthread_join(g_workers[i].thread, NULL);
    }

    if (shared_ssl_ctx) {
        tls_free_server_ctx(shared_ssl_ctx);
    }
    if (shared_ssl_ctx_h2) {
        tls_free_server_ctx(shared_ssl_ctx_h2);
    }

    free(g_workers);
    return 0;
}
