// ringzero-ws — a hand-rolled WebSocket echo server on raw io_uring (liburing).
//
// No WebSocket library: the RFC 6455 handshake (with from-scratch SHA-1 +
// base64), the frame parser, masking, and the echo path are all implemented
// here directly against io_uring completions.
//
// I/O model (the "ring-zero" part):
//   * one io_uring per core, each with its own SO_REUSEPORT listener
//     (kernel-sharded accept, no shared queue, no cross-core work-stealing)
//   * multishot accept  — one SQE yields every new connection
//   * multishot recv     — one SQE yields every read, into a *provided buffer
//     ring* so the kernel writes straight into our registered slab (zero-copy
//     ingest); frames are parsed in place and the buffer is recycled at once
//   * IORING_SETUP_SINGLE_ISSUER | DEFER_TASKRUN for the single-thread-per-ring
//     fast path
//
// Listens on 0.0.0.0:8080, WebSocket on path /ws. Usage: ./server [threads]

#define _GNU_SOURCE
#include <liburing.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// ── Tunables ────────────────────────────────────────────────────────────────
#define PORT 8080
#define SQ_ENTRIES 4096
#define CQ_ENTRIES 16384
#define BUF_COUNT 1024 // provided buffers per ring (power of 2)
#define BUF_SIZE 2048  // bytes per provided buffer
#define BGID 1         // buffer group id
#define MAX_FDS (1 << 20)
#define WS_GUID "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
#define MAX_FRAME (16u << 20)

// user_data tags
#define OP_ACCEPT 0u
#define OP_RECV 1u
#define OP_SEND 2u
#define OP_CLOSE 3u
#define UD(op, fd) (((uint64_t)(op) << 32) | (uint32_t)(fd))
#define UD_OP(x) ((unsigned)((x) >> 32))
#define UD_FD(x) ((int)((uint32_t)(x)))

// ── Types ───────────────────────────────────────────────────────────────────
typedef struct reactor {
    struct io_uring ring;
    struct io_uring_buf_ring *br;
    unsigned char *slab; // BUF_COUNT * BUF_SIZE
    int listen_fd;
    int cpu;
} reactor_t;

// A sealed-once outgoing chunk. Only wq_head is ever in flight; appends always
// target wq_tail, which is never the in-flight chunk, so realloc is safe.
typedef struct wbuf {
    struct wbuf *next;
    unsigned char *data;
    size_t len, cap, sent;
} wbuf;

typedef struct conn {
    int fd;
    int state;          // 0 = handshake, 1 = websocket
    int closing;        // teardown started
    int close_submitted;
    int want_close;     // close once the write queue drains
    int write_inflight;
    unsigned char *carry; // partial inbound bytes (handshake accum / partial frame)
    size_t carry_len, carry_cap;
    wbuf *wq_head, *wq_tail;
} conn_t;

static conn_t *g_conns[MAX_FDS]; // indexed by fd; each fd owned by one ring/thread

// ── small helpers ───────────────────────────────────────────────────────────
static int ensure_cap(unsigned char **buf, size_t *cap, size_t need) {
    if (*cap >= need) return 0;
    size_t nc = *cap ? *cap : 256;
    while (nc < need) nc *= 2;
    unsigned char *nb = realloc(*buf, nc);
    if (!nb) return -1;
    *buf = nb;
    *cap = nc;
    return 0;
}

static int carry_append(conn_t *c, const unsigned char *p, size_t n) {
    if (ensure_cap(&c->carry, &c->carry_cap, c->carry_len + n) != 0) return -1;
    memcpy(c->carry + c->carry_len, p, n);
    c->carry_len += n;
    return 0;
}

static int carry_set(conn_t *c, const unsigned char *p, size_t n) {
    if (ensure_cap(&c->carry, &c->carry_cap, n) != 0) return -1;
    memcpy(c->carry, p, n);
    c->carry_len = n;
    return 0;
}

static wbuf *wb_new(void) { return calloc(1, sizeof(wbuf)); }

static void append_out(conn_t *c, const unsigned char *p, size_t n) {
    wbuf *t = c->wq_tail;
    if (!t) {
        t = wb_new();
        if (!t) return;
        c->wq_head = c->wq_tail = t;
    }
    if (ensure_cap(&t->data, &t->cap, t->len + n) != 0) return;
    memcpy(t->data + t->len, p, n);
    t->len += n;
}

static void q_str(conn_t *c, const char *s) {
    append_out(c, (const unsigned char *)s, strlen(s));
}

static conn_t *conn_new(int fd) {
    conn_t *c = calloc(1, sizeof(conn_t));
    if (!c) return NULL;
    c->fd = fd;
    return c;
}

static void conn_free(conn_t *c) {
    free(c->carry);
    wbuf *w = c->wq_head;
    while (w) {
        wbuf *n = w->next;
        free(w->data);
        free(w);
        w = n;
    }
    free(c);
}

// ── SQE plumbing ────────────────────────────────────────────────────────────
static struct io_uring_sqe *get_sqe(reactor_t *r) {
    struct io_uring_sqe *sqe = io_uring_get_sqe(&r->ring);
    if (!sqe) {
        io_uring_submit(&r->ring);
        sqe = io_uring_get_sqe(&r->ring);
    }
    return sqe;
}

static void buf_recycle(reactor_t *r, int bid) {
    io_uring_buf_ring_add(r->br, r->slab + (size_t)bid * BUF_SIZE, BUF_SIZE, bid,
                          io_uring_buf_ring_mask(BUF_COUNT), 0);
    io_uring_buf_ring_advance(r->br, 1);
}

static void arm_accept(reactor_t *r) {
    struct io_uring_sqe *sqe = get_sqe(r);
    io_uring_prep_multishot_accept(sqe, r->listen_fd, NULL, NULL, 0);
    io_uring_sqe_set_data64(sqe, UD(OP_ACCEPT, r->listen_fd));
}

static void arm_recv(reactor_t *r, int fd) {
    struct io_uring_sqe *sqe = get_sqe(r);
    io_uring_prep_recv_multishot(sqe, fd, NULL, 0, 0);
    sqe->flags |= IOSQE_BUFFER_SELECT;
    sqe->buf_group = BGID;
    io_uring_sqe_set_data64(sqe, UD(OP_RECV, fd));
}

static void submit_send(reactor_t *r, conn_t *c) {
    wbuf *h = c->wq_head;
    struct io_uring_sqe *sqe = get_sqe(r);
    io_uring_prep_send(sqe, c->fd, h->data + h->sent, h->len - h->sent, MSG_NOSIGNAL);
    io_uring_sqe_set_data64(sqe, UD(OP_SEND, c->fd));
    c->write_inflight = 1;
    // Seal the in-flight chunk: future appends must not realloc it.
    if (c->wq_tail == h) {
        wbuf *nt = wb_new();
        if (nt) {
            h->next = nt;
            c->wq_tail = nt;
        }
    }
}

static void flush_out(reactor_t *r, conn_t *c) {
    if (c->closing || c->write_inflight) return;
    if (c->wq_head && c->wq_head->len > c->wq_head->sent) submit_send(r, c);
}

static void do_close(reactor_t *r, conn_t *c) {
    if (c->close_submitted) return;
    c->close_submitted = 1;
    struct io_uring_sqe *sqe = get_sqe(r);
    io_uring_prep_close(sqe, c->fd);
    io_uring_sqe_set_data64(sqe, UD(OP_CLOSE, c->fd));
}

static void begin_close(reactor_t *r, conn_t *c) {
    if (c->close_submitted) return;
    c->closing = 1;
    if (c->write_inflight) return; // defer until the send drains (on_send closes)
    do_close(r, c);
}

// ── Hand-rolled SHA-1 + base64 (handshake only) ─────────────────────────────
static uint32_t rol(uint32_t v, int n) { return (v << n) | (v >> (32 - n)); }

static void sha1(const unsigned char *data, size_t len, unsigned char out[20]) {
    uint32_t h0 = 0x67452301, h1 = 0xEFCDAB89, h2 = 0x98BADCFE, h3 = 0x10325476,
             h4 = 0xC3D2E1F0;
    uint64_t bitlen = (uint64_t)len * 8;
    size_t msglen = len + 1;
    while (msglen % 64 != 56) msglen++;
    msglen += 8;
    unsigned char *msg = calloc(1, msglen);
    memcpy(msg, data, len);
    msg[len] = 0x80;
    for (int i = 0; i < 8; i++) msg[msglen - 1 - i] = (bitlen >> (8 * i)) & 0xFF;

    for (size_t off = 0; off < msglen; off += 64) {
        uint32_t w[80];
        for (int i = 0; i < 16; i++)
            w[i] = (msg[off + i * 4] << 24) | (msg[off + i * 4 + 1] << 16) |
                   (msg[off + i * 4 + 2] << 8) | msg[off + i * 4 + 3];
        for (int i = 16; i < 80; i++)
            w[i] = rol(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
        uint32_t a = h0, b = h1, c = h2, d = h3, e = h4;
        for (int i = 0; i < 80; i++) {
            uint32_t f, k;
            if (i < 20) { f = (b & c) | ((~b) & d); k = 0x5A827999; }
            else if (i < 40) { f = b ^ c ^ d; k = 0x6ED9EBA1; }
            else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC; }
            else { f = b ^ c ^ d; k = 0xCA62C1D6; }
            uint32_t t = rol(a, 5) + f + e + k + w[i];
            e = d; d = c; c = rol(b, 30); b = a; a = t;
        }
        h0 += a; h1 += b; h2 += c; h3 += d; h4 += e;
    }
    free(msg);
    uint32_t hh[5] = {h0, h1, h2, h3, h4};
    for (int i = 0; i < 5; i++) {
        out[i * 4] = (hh[i] >> 24) & 0xFF;
        out[i * 4 + 1] = (hh[i] >> 16) & 0xFF;
        out[i * 4 + 2] = (hh[i] >> 8) & 0xFF;
        out[i * 4 + 3] = hh[i] & 0xFF;
    }
}

static void base64(const unsigned char *in, size_t len, char *out) {
    static const char T[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t o = 0;
    for (size_t i = 0; i < len; i += 3) {
        int rem = (int)(len - i);
        unsigned n = (unsigned)in[i] << 16;
        if (rem > 1) n |= (unsigned)in[i + 1] << 8;
        if (rem > 2) n |= (unsigned)in[i + 2];
        out[o++] = T[(n >> 18) & 63];
        out[o++] = T[(n >> 12) & 63];
        out[o++] = rem > 1 ? T[(n >> 6) & 63] : '=';
        out[o++] = rem > 2 ? T[n & 63] : '=';
    }
    out[o] = 0;
}

// ── WebSocket framing ───────────────────────────────────────────────────────
// Parse one frame from b[0..len). Unmasks payload in place. Returns the total
// frame size, 0 if incomplete, -1 on protocol error (oversized).
static int ws_parse_one(unsigned char *b, size_t len, int *fin, int *opcode,
                        unsigned char **pl, size_t *pn) {
    if (len < 2) return 0;
    int masked = b[1] & 0x80;
    size_t l = b[1] & 0x7F, off = 2;
    if (l == 126) {
        if (len < 4) return 0;
        l = ((size_t)b[2] << 8) | b[3];
        off = 4;
    } else if (l == 127) {
        if (len < 10) return 0;
        l = 0;
        for (int i = 0; i < 8; i++) l = (l << 8) | b[2 + i];
        if (l > MAX_FRAME) return -1;
        off = 10;
    }
    if (l > MAX_FRAME) return -1;
    unsigned char mask[4] = {0, 0, 0, 0};
    if (masked) {
        if (len < off + 4) return 0;
        memcpy(mask, b + off, 4);
        off += 4;
    }
    if (len < off + l) return 0;
    if (masked)
        for (size_t i = 0; i < l; i++) b[off + i] ^= mask[i & 3];
    *fin = (b[0] & 0x80) != 0;
    *opcode = b[0] & 0x0F;
    *pl = b + off;
    *pn = l;
    return (int)(off + l);
}

static void append_hdr(conn_t *c, int fin, int opcode, size_t len) {
    unsigned char h[10];
    size_t k;
    h[0] = (fin ? 0x80 : 0) | (opcode & 0x0F);
    if (len < 126) {
        h[1] = (unsigned char)len;
        k = 2;
    } else if (len <= 0xFFFF) {
        h[1] = 126;
        h[2] = (len >> 8) & 0xFF;
        h[3] = len & 0xFF;
        k = 4;
    } else {
        h[1] = 127;
        for (int i = 0; i < 8; i++) h[2 + i] = (len >> (8 * (7 - i))) & 0xFF;
        k = 10;
    }
    append_out(c, h, k);
}

static void ws_emit(conn_t *c, int fin, int opcode, unsigned char *pl, size_t pn) {
    append_hdr(c, fin, opcode, pn);
    append_out(c, pl, pn);
}

// Drain as many complete frames as possible from b[0..len). Echoes go to the
// write queue. Returns bytes consumed; sets *stop when the connection should
// close (Close frame or protocol error).
static size_t ws_drain(conn_t *c, unsigned char *b, size_t len, int *stop) {
    size_t off = 0;
    *stop = 0;
    while (off < len) {
        int fin, opcode;
        unsigned char *pl;
        size_t pn;
        int k = ws_parse_one(b + off, len - off, &fin, &opcode, &pl, &pn);
        if (k == 0) break;
        if (k < 0) {
            *stop = 1;
            c->want_close = 1;
            break;
        }
        if (opcode <= 0x2) { // continuation / text / binary → echo verbatim
            ws_emit(c, fin, opcode, pl, pn);
        } else if (opcode == 0x9) { // ping → pong
            ws_emit(c, 1, 0xA, pl, pn);
        } else if (opcode == 0x8) { // close → echo + finish
            ws_emit(c, 1, 0x8, pl, pn);
            c->want_close = 1;
            *stop = 1;
            off += k;
            break;
        } // pong / reserved → ignore
        off += k;
    }
    return off;
}

static void ws_drain_carry(conn_t *c) {
    int stop;
    size_t used = ws_drain(c, c->carry, c->carry_len, &stop);
    if (stop) {
        c->carry_len = 0;
        return;
    }
    size_t rem = c->carry_len - used;
    if (rem && used) memmove(c->carry, c->carry + used, rem);
    c->carry_len = rem;
}

// ── Handshake ───────────────────────────────────────────────────────────────
static int ci_eq(const unsigned char *a, size_t alen, const char *b) {
    if (alen != strlen(b)) return 0;
    for (size_t i = 0; i < alen; i++) {
        unsigned char x = a[i], y = (unsigned char)b[i];
        if (x >= 'A' && x <= 'Z') x += 32;
        if (y >= 'A' && y <= 'Z') y += 32;
        if (x != y) return 0;
    }
    return 1;
}

static ssize_t find_hdr_end(const unsigned char *b, size_t n) {
    for (size_t i = 0; i + 3 < n; i++)
        if (b[i] == '\r' && b[i + 1] == '\n' && b[i + 2] == '\r' && b[i + 3] == '\n')
            return (ssize_t)i;
    return -1;
}

// Parse the request in carry[0..he); reply 101 (ok) or 4xx. Consumes the header
// bytes from carry, leaving any trailing frame bytes. Returns 1 if upgraded.
static int do_handshake(conn_t *c, size_t he) {
    unsigned char *b = c->carry;
    // request line: METHOD SP PATH SP VERSION
    size_t i = 0;
    while (i < he && b[i] != '\r') i++;
    size_t rl = i; // request-line length
    size_t s1 = 0;
    while (s1 < rl && b[s1] != ' ') s1++;
    size_t ps = s1 + 1, pe = ps;
    while (pe < rl && b[pe] != ' ') pe++;
    int path_is_ws = (pe > ps) && ci_eq(b + ps, pe - ps, "/ws");

    char keybuf[128];
    int have_key = 0, upgrade = 0;
    size_t ls = (rl + 2 <= he) ? rl + 2 : he;
    while (ls < he) {
        size_t le = ls;
        while (le + 1 < he && !(b[le] == '\r' && b[le + 1] == '\n')) le++;
        size_t colon = ls;
        while (colon < le && b[colon] != ':') colon++;
        if (colon < le) {
            size_t ns = ls, nl = colon - ls;
            size_t vs = colon + 1;
            while (vs < le && (b[vs] == ' ' || b[vs] == '\t')) vs++;
            size_t ve = le;
            while (ve > vs && (b[ve - 1] == ' ' || b[ve - 1] == '\t')) ve--;
            if (ci_eq(b + ns, nl, "sec-websocket-key")) {
                size_t vl = ve - vs;
                if (vl < sizeof(keybuf) - 1) {
                    memcpy(keybuf, b + vs, vl);
                    keybuf[vl] = 0;
                    have_key = 1;
                }
            } else if (ci_eq(b + ns, nl, "upgrade") && ci_eq(b + vs, ve - vs, "websocket")) {
                upgrade = 1;
            }
        }
        ls = le + 2;
    }

    // Drop the consumed request bytes; keep any pipelined frame bytes.
    size_t consume = he + 4;
    size_t rem = c->carry_len - consume;
    if (rem) memmove(c->carry, c->carry + consume, rem);
    c->carry_len = rem;

    if (!path_is_ws) {
        q_str(c, "HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
        c->want_close = 1;
        return 0;
    }
    if (!have_key || !upgrade) {
        q_str(c, "HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
        c->want_close = 1;
        return 0;
    }

    unsigned char cat[200];
    size_t kl = strlen(keybuf);
    memcpy(cat, keybuf, kl);
    memcpy(cat + kl, WS_GUID, strlen(WS_GUID));
    unsigned char dig[20];
    sha1(cat, kl + strlen(WS_GUID), dig);
    char accept[40];
    base64(dig, 20, accept);

    char resp[256];
    int m = snprintf(resp, sizeof resp,
                     "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                     "Connection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n",
                     accept);
    append_out(c, (unsigned char *)resp, (size_t)m);
    return 1;
}

// ── Completion handlers ─────────────────────────────────────────────────────
static void on_recv_data(reactor_t *r, conn_t *c, unsigned char *data, size_t n) {
    if (c->state == 0) {
        if (carry_append(c, data, n) != 0) {
            begin_close(r, c);
            return;
        }
        ssize_t he = find_hdr_end(c->carry, c->carry_len);
        if (he < 0) {
            if (c->carry_len > 16384) {
                q_str(c, "HTTP/1.1 431 Request Header Fields Too Large\r\n"
                         "Connection: close\r\nContent-Length: 0\r\n\r\n");
                c->want_close = 1;
            }
            return;
        }
        if (!do_handshake(c, (size_t)he)) return; // invalid: response queued
        c->state = 1;
        ws_drain_carry(c);
    } else if (c->carry_len == 0) {
        int stop;
        size_t used = ws_drain(c, data, n, &stop);
        if (!stop && used < n)
            if (carry_set(c, data + used, n - used) != 0) begin_close(r, c);
    } else {
        if (carry_append(c, data, n) != 0) {
            begin_close(r, c);
            return;
        }
        ws_drain_carry(c);
    }
}

static void on_accept(reactor_t *r, struct io_uring_cqe *cqe) {
    if (cqe->res >= 0) {
        int cfd = cqe->res;
        if (cfd < MAX_FDS) {
            int one = 1;
            setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
            conn_t *c = conn_new(cfd);
            if (c) {
                g_conns[cfd] = c;
                arm_recv(r, cfd);
            } else {
                struct io_uring_sqe *s = get_sqe(r);
                io_uring_prep_close(s, cfd);
                io_uring_sqe_set_data64(s, UD(OP_CLOSE, cfd));
            }
        }
    }
    if (!(cqe->flags & IORING_CQE_F_MORE)) arm_accept(r); // re-arm if it ended
}

static void on_recv(reactor_t *r, struct io_uring_cqe *cqe, int fd) {
    conn_t *c = (fd >= 0 && fd < MAX_FDS) ? g_conns[fd] : NULL;
    int has_buf = (cqe->flags & IORING_CQE_F_BUFFER) != 0;
    int bid = has_buf ? (cqe->flags >> IORING_CQE_BUFFER_SHIFT) : -1;
    int more = (cqe->flags & IORING_CQE_F_MORE) != 0;

    if (!c || c->closing) {
        if (has_buf) buf_recycle(r, bid);
        return;
    }
    if (cqe->res == -ENOBUFS) {
        arm_recv(r, fd);
        return;
    }
    if (cqe->res <= 0) {
        if (has_buf) buf_recycle(r, bid);
        begin_close(r, c);
        return;
    }
    on_recv_data(r, c, r->slab + (size_t)bid * BUF_SIZE, (size_t)cqe->res);
    if (has_buf) buf_recycle(r, bid);
    flush_out(r, c);
    if (!more && !c->closing) arm_recv(r, fd);
    if (c->want_close && !c->closing) begin_close(r, c);
}

static void on_send(reactor_t *r, struct io_uring_cqe *cqe, int fd) {
    conn_t *c = (fd >= 0 && fd < MAX_FDS) ? g_conns[fd] : NULL;
    if (!c) return;
    if (cqe->res < 0) {
        c->write_inflight = 0;
        begin_close(r, c);
        if (c->closing) do_close(r, c);
        return;
    }
    wbuf *h = c->wq_head;
    h->sent += cqe->res;
    if (h->sent < h->len) { // partial — resend remainder of head
        submit_send(r, c);
        return;
    }
    c->wq_head = h->next;
    free(h->data);
    free(h);
    if (c->wq_head && c->wq_head->len > c->wq_head->sent) {
        submit_send(r, c);
        return;
    }
    c->write_inflight = 0;
    if (c->wq_head == NULL) c->wq_tail = NULL;
    if (c->closing) do_close(r, c);
    else if (c->want_close) begin_close(r, c);
}

static void on_close(conn_t *c, int fd) {
    if (c) {
        conn_free(c);
        g_conns[fd] = NULL;
    }
}

// ── Reactor ─────────────────────────────────────────────────────────────────
static int make_listener(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(PORT);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    if (listen(fd, SOMAXCONN) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static void *reactor_thread(void *arg) {
    reactor_t *r = arg;

    if (r->cpu >= 0) {
        cpu_set_t set;
        CPU_ZERO(&set);
        CPU_SET(r->cpu, &set);
        pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
    }

    r->listen_fd = make_listener();
    if (r->listen_fd < 0) {
        fprintf(stderr, "listener failed: %s\n", strerror(errno));
        return NULL;
    }

    struct io_uring_params p;
    memset(&p, 0, sizeof(p));
    p.flags = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN |
              IORING_SETUP_CQSIZE | IORING_SETUP_CLAMP;
    p.cq_entries = CQ_ENTRIES;
    if (io_uring_queue_init_params(SQ_ENTRIES, &r->ring, &p) < 0) {
        // Fall back for older kernels without DEFER_TASKRUN/SINGLE_ISSUER.
        memset(&p, 0, sizeof(p));
        p.flags = IORING_SETUP_CQSIZE | IORING_SETUP_CLAMP;
        p.cq_entries = CQ_ENTRIES;
        if (io_uring_queue_init_params(SQ_ENTRIES, &r->ring, &p) < 0) {
            fprintf(stderr, "io_uring_queue_init failed\n");
            return NULL;
        }
    }

    int ret = 0;
    r->br = io_uring_setup_buf_ring(&r->ring, BUF_COUNT, BGID, 0, &ret);
    if (!r->br) {
        fprintf(stderr, "buf_ring setup failed: %s\n", strerror(-ret));
        return NULL;
    }
    r->slab = aligned_alloc(4096, (size_t)BUF_COUNT * BUF_SIZE);
    unsigned mask = io_uring_buf_ring_mask(BUF_COUNT);
    for (int i = 0; i < BUF_COUNT; i++)
        io_uring_buf_ring_add(r->br, r->slab + (size_t)i * BUF_SIZE, BUF_SIZE, i, mask, i);
    io_uring_buf_ring_advance(r->br, BUF_COUNT);

    arm_accept(r);

    for (;;) {
        if (io_uring_submit_and_wait(&r->ring, 1) < 0 && errno == EINTR) continue;
        unsigned head, count = 0;
        struct io_uring_cqe *cqe;
        io_uring_for_each_cqe(&r->ring, head, cqe) {
            count++;
            uint64_t ud = io_uring_cqe_get_data64(cqe);
            switch (UD_OP(ud)) {
            case OP_ACCEPT: on_accept(r, cqe); break;
            case OP_RECV: on_recv(r, cqe, UD_FD(ud)); break;
            case OP_SEND: on_send(r, cqe, UD_FD(ud)); break;
            case OP_CLOSE:
                on_close((UD_FD(ud) >= 0 && UD_FD(ud) < MAX_FDS) ? g_conns[UD_FD(ud)] : NULL,
                         UD_FD(ud));
                break;
            }
        }
        io_uring_cq_advance(&r->ring, count);
    }
    return NULL;
}

int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);

    cpu_set_t set;
    int ncpu = 0, cpus[CPU_SETSIZE];
    if (sched_getaffinity(0, sizeof(set), &set) == 0) {
        for (int i = 0; i < CPU_SETSIZE; i++)
            if (CPU_ISSET(i, &set)) cpus[ncpu++] = i;
    }
    if (ncpu == 0) {
        cpus[0] = -1;
        ncpu = 1;
    }

    int threads = (argc > 1) ? atoi(argv[1]) : ncpu;
    if (threads <= 0) threads = ncpu;

    fprintf(stderr, "ringzero-ws: %d reactors on :%d (io_uring + provided buffers)\n",
            threads, PORT);

    pthread_t *th = calloc(threads, sizeof(pthread_t));
    reactor_t *rs = calloc(threads, sizeof(reactor_t));
    for (int i = 0; i < threads; i++) {
        rs[i].cpu = cpus[i % ncpu];
        pthread_create(&th[i], NULL, reactor_thread, &rs[i]);
    }
    for (int i = 0; i < threads; i++) pthread_join(th[i], NULL);
    return 0;
}
