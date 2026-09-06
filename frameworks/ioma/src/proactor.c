#define _GNU_SOURCE
#include "proactor.h"

#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <unistd.h>

#define BGID     1
#define RX_MASK  (RX_QUEUE - 1)
#define BUF_MASK (BUF_COUNT - 1)

/* -DTRACE: one line per completion and lifetime event, for chasing a misbehaving path */
#ifdef TRACE
#define trace(...) fprintf(stderr, __VA_ARGS__)
#else
#define trace(...) ((void)0)
#endif

/* Completion routing: user_data is a pointer with a tag in its low three bits (everything we
 * point at is at least 8-byte aligned). ioxide packs a kind byte, a generation and an fd and
 * looks the connection up in a table; here the coroutine's own stack frame, or the heap
 * connection a multishot belongs to, is the key. */
enum { TAG_OP = 0, TAG_RECV = 1, TAG_ACCEPT = 2, TAG_IGNORE = 3 };
#define UD(ptr, tag) ((uint64_t)(uintptr_t)(ptr) | (uint64_t)(tag))
#define UD_PTR(ud)   ((void *)(uintptr_t)((ud) & ~(uint64_t)7))
#define UD_TAG(ud)   ((unsigned)((ud) & 7))

/* A one-shot operation. Lives in the awaiting coroutine's stack frame: that frame is frozen
 * while the coroutine is parked, so its address stays valid for exactly as long as the
 * operation is in flight. */
typedef struct op {
    coro_t  *waiter;
    int      res;
    unsigned flags;
} op_t;

/* ── SQEs ──────────────────────────────────────────────────────────────────────────────── */

static struct io_uring_sqe *get_sqe(proactor_t *p)
{
    struct io_uring_sqe *sqe = uring_get_sqe(&p->ring);
    for (int i = 0; !sqe && i < 16; i++) {       /* SQ full mid-batch: flush, never wait */
        uring_submit(&p->ring);
        sqe = uring_get_sqe(&p->ring);
    }
    if (!sqe) {
        fprintf(stderr, "[w%d] SQ still full after flushing\n", p->id);
        abort();
    }
    return sqe;
}

/* Stage a one-shot op and park until its CQE. The loop fills op->res and resumes us. */
static int await_op(struct io_uring_sqe *sqe, op_t *op)
{
    op->waiter = coro_current();
    sqe->user_data = UD(op, TAG_OP);
    coro_yield();
    return op->res;
}

static void submit_cancel(proactor_t *p, uint64_t target_user_data)
{
    struct io_uring_sqe *sqe = get_sqe(p);
    sqe->opcode    = IORING_OP_ASYNC_CANCEL;
    sqe->fd        = -1;
    sqe->addr      = target_user_data;
    sqe->user_data = TAG_IGNORE;
}

/* ── provided buffers ──────────────────────────────────────────────────────────────────── */

static void *map_pages(size_t bytes)
{
    void *m = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (m == MAP_FAILED) {
        perror("mmap");
        abort();
    }
    return m;
}

static void bufring_init(proactor_t *p)
{
    size_t ring_bytes = (size_t)BUF_COUNT * sizeof(struct io_uring_buf);
    p->buf_ring = map_pages(ring_bytes);
    p->slab     = map_pages((size_t)BUF_COUNT * BUF_SIZE);

    struct io_uring_buf_reg reg;
    memset(&reg, 0, sizeof reg);
    reg.ring_addr    = (uint64_t)(uintptr_t)p->buf_ring;
    reg.ring_entries = BUF_COUNT;
    reg.bgid         = BGID;
    int rc = uring_register(&p->ring, IORING_REGISTER_PBUF_RING, &reg, 1);
    if (rc < 0) {
        fprintf(stderr, "[w%d] register pbuf ring: %s\n", p->id, strerror(-rc));
        abort();
    }

    /* Fill every slot, then publish the tail once. bufs[0] overlaps the ring header and the tail
     * is at offset 14 (bufs[0].resv), so writing only addr/len/bid leaves it untouched. */
    for (unsigned i = 0; i < BUF_COUNT; i++) {
        struct io_uring_buf *b = &p->buf_ring->bufs[i];
        b->addr = (uint64_t)(uintptr_t)(p->slab + (size_t)i * BUF_SIZE);
        b->len  = BUF_SIZE;
        b->bid  = (uint16_t)i;
    }
    p->buf_tail = BUF_COUNT;
    __atomic_store_n(&p->buf_ring->tail, (uint16_t)p->buf_tail, __ATOMIC_RELEASE);
}

/* Hand a buffer back to the kernel. Called by a handler (through await_recv) or the loop. */
static void return_buf(proactor_t *p, uint16_t bid)
{
    struct io_uring_buf *b = &p->buf_ring->bufs[p->buf_tail & BUF_MASK];
    b->addr = (uint64_t)(uintptr_t)(p->slab + (size_t)bid * BUF_SIZE);
    b->len  = BUF_SIZE;
    b->bid  = bid;
    p->buf_tail++;
    __atomic_store_n(&p->buf_ring->tail, (uint16_t)p->buf_tail, __ATOMIC_RELEASE);
    p->buffers_returned = true;                  /* lets the loop re-arm starved recvs */
}

/* ── connections ───────────────────────────────────────────────────────────────────────── */

static conn_t *conn_new(proactor_t *p, int fd)
{
    conn_t *c = calloc(1, sizeof *c);
    if (!c) {
        perror("calloc");
        abort();
    }
    c->fd   = fd;
    c->p    = p;
    c->refs = 2;                                 /* the handler coroutine and the multishot recv */
    p->live++;
    return c;
}

static void conn_unref(conn_t *c)
{
    if (--c->refs == 0) {
        c->p->live--;
        free(c);
    }
}

static void arm_recv(proactor_t *p, conn_t *c)
{
    struct io_uring_sqe *sqe = get_sqe(p);
    sqe->opcode    = IORING_OP_RECV;
    sqe->fd        = c->fd;
    sqe->flags     = IOSQE_BUFFER_SELECT;        /* the kernel picks a buffer from BGID */
    sqe->ioprio    = IORING_RECV_MULTISHOT;      /* armed once, a CQE per arrival       */
    sqe->buf_group = BGID;
    sqe->user_data = UD(c, TAG_RECV);
    c->recv = RECV_ARMED;
}

static void wake_reader(conn_t *c)
{
    coro_t *w = c->waiter;
    if (w) {
        c->waiter = NULL;
        coro_resume(w);                          /* it pops the queue itself; may run far */
    }
}

static void starved_push(proactor_t *p, conn_t *c)
{
    if (p->nstarved == p->cap_starved) {
        p->cap_starved = p->cap_starved ? p->cap_starved * 2 : 64;
        p->starved = realloc(p->starved, p->cap_starved * sizeof *p->starved);
        if (!p->starved) {
            perror("realloc");
            abort();
        }
    }
    p->starved[p->nstarved++] = c;
}

static void starved_remove(proactor_t *p, conn_t *c)
{
    for (unsigned i = 0; i < p->nstarved; i++) {
        if (p->starved[i] == c) {
            p->starved[i] = p->starved[--p->nstarved];
            return;
        }
    }
}

/* Runs once when the handler returns: close the fd, let the recv wind down, drop the ref. */
static void conn_close(conn_t *c)
{
    proactor_t *p = c->p;
    c->closed = true;
    trace("[w%d] close fd=%d state=%d eof=%d err=%d queued=%u\n",
          p->id, c->fd, c->recv, c->eof, c->err, c->rx_tail - c->rx_head);

    if (c->recv == RECV_ARMED) {
        submit_cancel(p, UD(c, TAG_RECV));       /* its ref drops on the -ECANCELED CQE */
    } else if (c->recv == RECV_STARVED) {
        starved_remove(p, c);
        c->recv = RECV_DONE;
        conn_unref(c);
    }
    while (c->rx_head != c->rx_tail)             /* unread slices go back to the ring */
        return_buf(p, c->rx[c->rx_head++ & RX_MASK].bid);

    close(c->fd);
    conn_unref(c);                               /* the handler's ref */
}

static void handler_main(void *arg)
{
    conn_t *c = arg;
    c->p->handler(c);
    conn_close(c);
}

/* ── completions ───────────────────────────────────────────────────────────────────────── */

static void on_recv(proactor_t *p, conn_t *c, int res, unsigned flags)
{
    bool     more    = flags & IORING_CQE_F_MORE;
    bool     has_buf = flags & IORING_CQE_F_BUFFER;
    uint16_t bid     = (uint16_t)(flags >> IORING_CQE_BUFFER_SHIFT);

    trace("[w%d] recv fd=%d res=%d more=%d buf=%d bid=%u queued=%u state=%d closed=%d eof=%d\n",
          p->id, c->fd, res, more, has_buf, bid, c->rx_tail - c->rx_head, c->recv, c->closed, c->eof);

    if (res == -ENOBUFS) {
        /* The buffer group ran dry, so the multishot ended (no F_MORE). Park the connection;
         * the loop re-arms it once any buffer comes back. Not a peer error. */
        if (c->closed) {
            c->recv = RECV_DONE;
            conn_unref(c);
            return;
        }
        c->recv = RECV_STARVED;
        starved_push(p, c);
        return;
    }

    if (res <= 0) {
        /* Terminal: peer FIN (0), a socket error, or -ECANCELED from our own close. */
        if (has_buf)
            return_buf(p, bid);
        if (!c->eof) {
            c->eof = true;
            c->err = res;
        }
        c->recv = RECV_DONE;
        wake_reader(c);                          /* a parked await_recv returns 0 / -errno */
        conn_unref(c);                           /* the recv's ref; may free c */
        return;
    }

    /* data */
    if (c->closed) {
        return_buf(p, bid);                      /* the handler is gone; nobody will read it */
    } else if (c->rx_tail - c->rx_head == RX_QUEUE) {
        /* The handler is not draining. Rather than let one peer hoard the buffer group, end the
         * connection's input: it sees -ENOBUFS on its next read. */
        return_buf(p, bid);
        if (!c->eof) {
            c->eof = true;
            c->err = -ENOBUFS;
        }
        if (more)
            submit_cancel(p, UD(c, TAG_RECV));
        wake_reader(c);
    } else {
        struct rx_item *it = &c->rx[c->rx_tail++ & RX_MASK];
        it->ptr = p->slab + (size_t)bid * BUF_SIZE;
        it->len = (uint32_t)res;
        it->bid = bid;
        wake_reader(c);
    }

    if (!more) {
        /* The kernel ended the multishot after delivering; keep receiving unless the connection
         * is finished (the reader may have closed it while it ran). */
        if (!c->closed && !c->eof)
            arm_recv(p, c);
        else {
            c->recv = RECV_DONE;
            conn_unref(c);
        }
    }
}

static void arm_accept(proactor_t *p)
{
    struct io_uring_sqe *sqe = get_sqe(p);
    sqe->opcode    = IORING_OP_ACCEPT;
    sqe->fd        = p->listen_fd;
    sqe->ioprio    = IORING_ACCEPT_MULTISHOT;    /* armed once, a CQE per connection */
    sqe->user_data = UD(p, TAG_ACCEPT);
}

static void on_accept(proactor_t *p, int res, unsigned flags)
{
    trace("[w%d] accept res=%d more=%d\n", p->id, res, !!(flags & IORING_CQE_F_MORE));
    if (res >= 0) {
        int one = 1;
        setsockopt(res, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);   /* doesn't inherit */
        conn_t *c = conn_new(p, res);
        arm_recv(p, c);
        proactor_spawn(p, handler_main, c);
        p->accepted++;
    } else {
        fprintf(stderr, "[w%d] accept: %s\n", p->id, strerror(-res));
    }
    if (!(flags & IORING_CQE_F_MORE))
        arm_accept(p);
}

static void dispatch(proactor_t *p, struct io_uring_cqe *cqe)
{
    void *ptr = UD_PTR(cqe->user_data);
    switch (UD_TAG(cqe->user_data)) {
    case TAG_OP: {
        op_t *op  = ptr;
        op->res   = cqe->res;
        op->flags = cqe->flags;
        trace("[w%d] op res=%d flags=%#x\n", p->id, cqe->res, cqe->flags);
        coro_resume(op->waiter);                 /* to its next await; op may be gone after */
        break;
    }
    case TAG_RECV:
        on_recv(p, ptr, cqe->res, cqe->flags);
        break;
    case TAG_ACCEPT:
        on_accept(p, cqe->res, cqe->flags);
        break;
    default:                                     /* TAG_IGNORE: cancel acknowledgements */
        break;
    }
}

/* ── awaits ────────────────────────────────────────────────────────────────────────────── */

int await_recv(conn_t *c, void *buf, size_t len)
{
    if (len == 0)
        return -EINVAL;
    for (;;) {
        if (c->rx_head != c->rx_tail) {
            struct rx_item *it = &c->rx[c->rx_head & RX_MASK];
            size_t n = it->len < len ? it->len : len;
            memcpy(buf, it->ptr, n);
            it->ptr += n;
            it->len -= (uint32_t)n;
            if (it->len == 0) {
                return_buf(c->p, it->bid);
                c->rx_head++;
            }
            return (int)n;
        }
        if (c->eof)
            return c->err;
        c->waiter = coro_current();
        coro_yield();                            /* on_recv wakes us */
    }
}

int await_send(conn_t *c, const void *buf, size_t len)
{
    const uint8_t *cur = buf;
    size_t left = len;
    while (left > 0) {
        op_t op;
        struct io_uring_sqe *sqe = get_sqe(c->p);
        sqe->opcode    = IORING_OP_SEND;
        sqe->fd        = c->fd;
        sqe->addr      = (uint64_t)(uintptr_t)cur;
        sqe->len       = left > UINT32_MAX ? UINT32_MAX : (uint32_t)left;
        sqe->msg_flags = MSG_NOSIGNAL | MSG_WAITALL;   /* no SIGPIPE; the kernel retries short sends */
        int n = await_op(sqe, &op);
        if (n < 0)
            return n;
        if (n == 0)
            return -EPIPE;
        cur  += n;
        left -= (size_t)n;
    }
    return (int)len;
}

/* ── scheduling ────────────────────────────────────────────────────────────────────────── */

void proactor_spawn(proactor_t *p, void (*fn)(void *), void *arg)
{
    coro_t *c = coro_create(fn, arg, STACK_SIZE);
    if (p->ready_tail)
        p->ready_tail->next = c;
    else
        p->ready_head = c;
    p->ready_tail = c;
}

static void run_ready(proactor_t *p)
{
    while (p->ready_head) {
        coro_t *c = p->ready_head;
        p->ready_head = c->next;
        if (!p->ready_head)
            p->ready_tail = NULL;
        c->next = NULL;
        coro_resume(c);
    }
}

/* Re-arm every recv parked on -ENOBUFS, but only once a buffer actually came back: a parked
 * connection must not spin the loop, and one that drains the group again just parks again. */
static void rearm_starved(proactor_t *p)
{
    if (p->nstarved == 0 || !p->buffers_returned)
        return;
    p->buffers_returned = false;
    for (unsigned i = 0; i < p->nstarved; i++)
        arm_recv(p, p->starved[i]);              /* keeps the ref it already holds */
    p->nstarved = 0;
}

/* ── listener ──────────────────────────────────────────────────────────────────────────── */

static int listener_open(uint16_t port)
{
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        perror("socket");
        abort();
    }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);   /* one listener per worker */

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_family      = AF_INET;
    addr.sin_port        = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
        perror("bind");
        abort();
    }
    if (listen(fd, 1024) < 0) {
        perror("listen");
        abort();
    }
    return fd;
}

/* ── the loop ──────────────────────────────────────────────────────────────────────────── */

/* Pin worker `idx` to the idx-th CPU the process is actually allowed to run on. Reading the
 * inherited affinity mask (rather than assuming CPUs 0..n-1) keeps the mapping correct under a
 * non-contiguous cpuset, e.g. a container pinned to 0-31,64-95. */
static void pin_to(int idx)
{
    cpu_set_t allowed;
    CPU_ZERO(&allowed);
    if (sched_getaffinity(0, sizeof allowed, &allowed) != 0)
        return;

    int count = CPU_COUNT(&allowed);
    if (count <= 0)
        return;

    int target = idx % count;
    int seen = 0;
    for (int cpu = 0; cpu < CPU_SETSIZE; cpu++) {
        if (!CPU_ISSET(cpu, &allowed))
            continue;
        if (seen == target) {
            cpu_set_t one;
            CPU_ZERO(&one);
            CPU_SET(cpu, &one);
            pthread_setaffinity_np(pthread_self(), sizeof one, &one);
            return;
        }
        seen++;
    }
}

void proactor_run(proactor_t *p)
{
    if (p->cpu >= 0)
        pin_to(p->cpu);

    int rc = uring_init(&p->ring, RING_ENTRIES);           /* on this thread, for DEFER_TASKRUN */
    if (rc < 0) {
        fprintf(stderr, "[w%d] io_uring_setup: %s\n", p->id, strerror(-rc));
        abort();
    }
    bufring_init(p);
    p->listen_fd = listener_open(p->port);
    arm_accept(p);
    fprintf(stderr, "[w%d] listening on 0.0.0.0:%u (cpu %d, %u x %u B recv buffers, ring %u%s)\n",
            p->id, p->port, p->cpu, BUF_COUNT, BUF_SIZE, p->ring.sq_entries,
            p->ring.has_sq_array ? "" : ", no sqarray");

    struct __kernel_timespec ts = { .tv_sec = 0, .tv_nsec = 100 * 1000 * 1000 };   /* stop check */
    while (!*p->stop) {
        run_ready(p);
        rearm_starved(p);

        rc = uring_submit_wait(&p->ring, 1, &ts);            /* one syscall per batch */
        if (rc < 0 && rc != -ETIME && rc != -EINTR && rc != -EAGAIN && rc != -EBUSY) {
            fprintf(stderr, "[w%d] io_uring_enter: %s\n", p->id, strerror(-rc));
            break;
        }

        unsigned n = uring_cq_ready(&p->ring);               /* read the tail once   */
        for (unsigned i = 0; i < n; i++)
            dispatch(p, uring_cqe_at(&p->ring, i));          /* handlers run in here */
        uring_cq_advance(&p->ring, n);                       /* publish the head once */
    }

    fprintf(stderr, "[w%d] stopping: %llu accepted, %u still open\n",
            p->id, (unsigned long long)p->accepted, p->live);

    /* Teardown in dependency order: sockets, then the ring (which cancels every in-flight op and
     * drops its buffer references), then the memory the kernel could still have referenced. */
    close(p->listen_fd);
    struct io_uring_buf_reg reg;
    memset(&reg, 0, sizeof reg);
    reg.bgid = BGID;
    uring_register(&p->ring, IORING_UNREGISTER_PBUF_RING, &reg, 1);
    uring_exit(&p->ring);
    munmap(p->buf_ring, (size_t)BUF_COUNT * sizeof(struct io_uring_buf));
    munmap(p->slab, (size_t)BUF_COUNT * BUF_SIZE);
    free(p->starved);
}
