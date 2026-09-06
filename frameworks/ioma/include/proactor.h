/*
 * proactor.h - one worker: one thread, one io_uring, one SO_REUSEPORT listener, one provided
 * buffer ring, and the coroutines that run on it. Thread-per-core, shared-nothing: nothing in
 * here is touched by any other thread except the stop flag.
 *
 * The loop: run freshly spawned coroutines, re-arm recvs parked on -ENOBUFS, publish and enter
 * once (submit everything staged, wait for >= 1 completion), dispatch the whole CQ batch, advance
 * the head once. Dispatching resumes handler coroutines inline, so the sends they stage ride the
 * next enter together with the batch.
 */
#pragma once

#include <signal.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "coro.h"
#include "uring.h"

/* tunables (override with -D) */
#ifndef RING_ENTRIES
#define RING_ENTRIES 4096                 /* SQ depth; the CQ is twice that                     */
#endif
#ifndef BUF_COUNT
#define BUF_COUNT    4096                 /* provided recv buffers per worker, power of two     */
#endif
#ifndef BUF_SIZE
#define BUF_SIZE     4096                 /* bytes per recv buffer                              */
#endif
#ifndef RX_QUEUE
#define RX_QUEUE     64                   /* undelivered slices one connection may hold, pow 2  */
#endif
#ifndef STACK_SIZE
#define STACK_SIZE   (64 * 1024)          /* per coroutine, plus a guard page                   */
#endif

typedef struct proactor proactor_t;
typedef struct conn     conn_t;
typedef void (*handler_fn)(conn_t *c);

/* A slice the kernel delivered into a provided buffer, waiting for the handler to read it. */
struct rx_item {
    uint8_t *ptr;
    uint32_t len;
    uint16_t bid;
};

enum recv_state {
    RECV_ARMED,                           /* multishot recv in flight; the kernel may post CQEs */
    RECV_STARVED,                         /* it ended on -ENOBUFS; re-armed once buffers return */
    RECV_DONE,                            /* it posted its terminal CQE                         */
};

struct conn {
    int             fd;
    proactor_t     *p;
    coro_t         *waiter;               /* coroutine parked in await_recv, or NULL           */
    struct rx_item  rx[RX_QUEUE];         /* delivered while nobody was reading                */
    unsigned        rx_head, rx_tail;
    enum recv_state recv;
    int             refs;                 /* the handler coroutine + the armed/starved recv    */
    bool            closed;               /* the handler returned; fd closed                   */
    bool            eof;                  /* recv ended: peer FIN, error, or queue overflow    */
    int             err;                  /* 0 on FIN, else the negative errno                 */
};

struct proactor {
    /* set by the creator */
    int                    id;
    int                    cpu;           /* pin the thread here; -1 = don't                   */
    uint16_t               port;
    handler_fn             handler;
    volatile sig_atomic_t *stop;

    /* owned by the worker thread */
    struct uring              ring;
    int                       listen_fd;
    struct io_uring_buf_ring *buf_ring;   /* kernel-shared ring of buffer descriptors          */
    uint8_t                  *slab;       /* BUF_COUNT x BUF_SIZE                              */
    unsigned                  buf_tail;   /* local tail, published to buf_ring->tail           */
    bool                      buffers_returned;   /* since the last starved sweep              */
    conn_t                  **starved;    /* connections parked on -ENOBUFS                    */
    unsigned                  nstarved, cap_starved;
    coro_t                   *ready_head, *ready_tail;   /* spawned, not yet started           */
    unsigned                  live;       /* open connections                                  */
    uint64_t                  accepted;
};

/* The worker thread's whole life: ring, buffers, listener, loop until *stop, teardown. */
void proactor_run(proactor_t *p);

/* Start a coroutine on this worker. Safe from the loop or from any coroutine on it. */
void proactor_spawn(proactor_t *p, void (*fn)(void *), void *arg);

/* Awaits: call from a coroutine on the owning worker. The coroutine parks; the loop resumes it
 * when the completion arrives. */
int await_recv(conn_t *c, void *buf, size_t len);        /* >0 bytes, 0 peer closed, <0 -errno */
int await_send(conn_t *c, const void *buf, size_t len);  /* len when all sent, else -errno     */
