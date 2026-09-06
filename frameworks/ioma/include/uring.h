/*
 * uring.h - raw io_uring, no liburing. The C twin of ioxide's Ring.cs.
 *
 * Setup with SINGLE_ISSUER | DEFER_TASKRUN | NO_SQARRAY, mmap the rings, claim SQEs against a
 * local tail, publish the tail and enter in one call, drain the CQ as a batch with one barrier
 * per batch. One ring per thread; nothing here is thread-safe and nothing needs to be.
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <linux/io_uring.h>

struct uring {
    int fd;

    /* submission side */
    unsigned *sq_head;                 /* kernel-written consumer index            */
    unsigned *sq_tail;                 /* our published producer index             */
    unsigned *sq_array;                /* SQ index array; unused under NO_SQARRAY  */
    unsigned  sq_mask, sq_entries;
    unsigned  sqe_tail;                /* local tail: claimed, not yet published   */
    struct io_uring_sqe *sqes;
    bool      has_sq_array;

    /* completion side */
    unsigned *cq_head;                 /* our consumer index                       */
    unsigned *cq_tail;                 /* kernel-written producer index            */
    unsigned  cq_mask;
    struct io_uring_cqe *cqes;

    /* mappings */
    void  *ring_mem; size_t ring_bytes;
    void  *sqe_mem;  size_t sqe_bytes;
};

/* Create the ring on the calling thread (DEFER_TASKRUN ties the ring to it). 0 or -errno. */
int  uring_init(struct uring *r, unsigned entries);
void uring_exit(struct uring *r);

/* Claim the next SQE, zeroed. NULL when the SQ is full: submit, then try again. */
struct io_uring_sqe *uring_get_sqe(struct uring *r);

/* Publish claimed SQEs and enter. uring_submit never waits; uring_submit_wait blocks until
 * wait_nr completions are available or ts (may be NULL) expires. Return: submitted count or
 * -errno (-ETIME on timeout). Under DEFER_TASKRUN only the waiting form reaps completions. */
int  uring_submit(struct uring *r);
int  uring_submit_wait(struct uring *r, unsigned wait_nr, struct __kernel_timespec *ts);

int  uring_register(struct uring *r, unsigned opcode, void *arg, unsigned nr_args);

/* Batched CQ drain: read the tail once, index the batch, publish the head once. */
unsigned uring_cq_ready(struct uring *r);
static inline struct io_uring_cqe *uring_cqe_at(struct uring *r, unsigned i)
{
    return &r->cqes[(*r->cq_head + i) & r->cq_mask];
}
void uring_cq_advance(struct uring *r, unsigned n);
