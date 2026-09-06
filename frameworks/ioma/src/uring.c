#define _GNU_SOURCE
#include "uring.h"

#include <errno.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

#define load_acquire(p)     __atomic_load_n((p), __ATOMIC_ACQUIRE)
#define store_release(p, v) __atomic_store_n((p), (v), __ATOMIC_RELEASE)

static int sys_setup(unsigned entries, struct io_uring_params *p)
{
    long r = syscall(SYS_io_uring_setup, entries, p);
    return r < 0 ? -errno : (int)r;
}

static int sys_enter(int fd, unsigned to_submit, unsigned min_complete, unsigned flags,
                     const void *arg, size_t argsz)
{
    long r = syscall(SYS_io_uring_enter, fd, to_submit, min_complete, flags, arg, argsz);
    return r < 0 ? -errno : (int)r;
}

int uring_register(struct uring *r, unsigned opcode, void *arg, unsigned nr_args)
{
    long ret = syscall(SYS_io_uring_register, r->fd, opcode, arg, nr_args);
    return ret < 0 ? -errno : (int)ret;
}

int uring_init(struct uring *r, unsigned entries)
{
    memset(r, 0, sizeof *r);

    /* SINGLE_ISSUER: only this thread submits, the kernel skips SQ locking.
     * DEFER_TASKRUN: completion work runs batched inside enter(GETEVENTS), never as an interrupt.
     * NO_SQARRAY (6.6+): slot i of the SQ ring is SQE i, one store fewer per submission. */
    struct io_uring_params p;
    memset(&p, 0, sizeof p);
    p.flags = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN | IORING_SETUP_NO_SQARRAY;
    int fd = sys_setup(entries, &p);
    if (fd == -EINVAL) {
        memset(&p, 0, sizeof p);
        p.flags = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN;
        fd = sys_setup(entries, &p);
        r->has_sq_array = true;
    }
    if (fd < 0)
        return fd;
    if (!(p.features & IORING_FEAT_SINGLE_MMAP)) {   /* every kernel since 5.4 */
        close(fd);
        return -ENOSYS;
    }
    r->fd = fd;
    r->sq_entries = p.sq_entries;

    /* one mapping holds both rings; size it for whichever ends later */
    size_t sq_bytes = p.sq_off.array + (size_t)p.sq_entries * sizeof(unsigned);
    size_t cq_bytes = p.cq_off.cqes  + (size_t)p.cq_entries * sizeof(struct io_uring_cqe);
    r->ring_bytes = sq_bytes > cq_bytes ? sq_bytes : cq_bytes;
    r->ring_mem = mmap(NULL, r->ring_bytes, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE,
                       fd, IORING_OFF_SQ_RING);
    if (r->ring_mem == MAP_FAILED) {
        int e = -errno;
        close(fd);
        return e;
    }

    r->sqe_bytes = (size_t)p.sq_entries * sizeof(struct io_uring_sqe);
    r->sqe_mem = mmap(NULL, r->sqe_bytes, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE,
                      fd, IORING_OFF_SQES);
    if (r->sqe_mem == MAP_FAILED) {
        int e = -errno;
        munmap(r->ring_mem, r->ring_bytes);
        close(fd);
        return e;
    }

    char *ring = r->ring_mem;
    r->sq_head  = (unsigned *)(ring + p.sq_off.head);
    r->sq_tail  = (unsigned *)(ring + p.sq_off.tail);
    r->sq_array = (unsigned *)(ring + p.sq_off.array);
    r->sq_mask  = *(unsigned *)(ring + p.sq_off.ring_mask);
    r->sqes     = r->sqe_mem;

    r->cq_head  = (unsigned *)(ring + p.cq_off.head);
    r->cq_tail  = (unsigned *)(ring + p.cq_off.tail);
    r->cq_mask  = *(unsigned *)(ring + p.cq_off.ring_mask);
    r->cqes     = (struct io_uring_cqe *)(ring + p.cq_off.cqes);
    return 0;
}

void uring_exit(struct uring *r)
{
    if (r->sqe_mem)  munmap(r->sqe_mem, r->sqe_bytes);
    if (r->ring_mem) munmap(r->ring_mem, r->ring_bytes);
    if (r->fd > 0)   close(r->fd);
    memset(r, 0, sizeof *r);
}

struct io_uring_sqe *uring_get_sqe(struct uring *r)
{
    unsigned head = load_acquire(r->sq_head);
    if (r->sqe_tail - head >= r->sq_entries)
        return NULL;                                   /* full: the caller flushes and retries */

    unsigned slot = r->sqe_tail & r->sq_mask;
    if (r->has_sq_array)
        r->sq_array[slot] = slot;
    r->sqe_tail++;

    struct io_uring_sqe *sqe = &r->sqes[slot];
    memset(sqe, 0, sizeof *sqe);
    return sqe;
}

static int flush_and_enter(struct uring *r, unsigned wait_nr, unsigned flags,
                           const void *arg, size_t argsz)
{
    /* Count against the kernel-consumed head, so SQEs an -EBUSY enter left unconsumed are
     * re-counted by the next call instead of stranding (liburing's accounting, ioxide's too). */
    unsigned khead = load_acquire(r->sq_head);
    unsigned to_submit = r->sqe_tail - khead;

    if (*r->sq_tail != r->sqe_tail)
        store_release(r->sq_tail, r->sqe_tail);

    if (to_submit == 0 && wait_nr == 0 && !(flags & IORING_ENTER_GETEVENTS))
        return 0;
    return sys_enter(r->fd, to_submit, wait_nr, flags, arg, argsz);
}

int uring_submit(struct uring *r)
{
    return flush_and_enter(r, 0, 0, NULL, 0);
}

int uring_submit_wait(struct uring *r, unsigned wait_nr, struct __kernel_timespec *ts)
{
    if (!ts)
        return flush_and_enter(r, wait_nr, IORING_ENTER_GETEVENTS, NULL, 0);

    struct io_uring_getevents_arg arg;
    memset(&arg, 0, sizeof arg);
    arg.ts = (uint64_t)(uintptr_t)ts;
    return flush_and_enter(r, wait_nr, IORING_ENTER_GETEVENTS | IORING_ENTER_EXT_ARG,
                           &arg, sizeof arg);
}

unsigned uring_cq_ready(struct uring *r)
{
    return load_acquire(r->cq_tail) - *r->cq_head;
}

void uring_cq_advance(struct uring *r, unsigned n)
{
    store_release(r->cq_head, *r->cq_head + n);
}
