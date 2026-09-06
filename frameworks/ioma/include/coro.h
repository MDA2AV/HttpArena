/*
 * coro.h - stackful coroutines for one proactor thread.
 *
 * A coroutine runs on its own mmap'd stack with a guard page. Suspending saves the callee-saved
 * registers and switches to the loop's stack; resuming is the reverse. Everything on the
 * coroutine's stack stays exactly where it was while it is parked, which is what lets an
 * io_uring completion be routed to a struct that lives in an await's frame.
 *
 * Discipline: only the loop calls coro_resume, only a coroutine calls coro_yield. A coroutine
 * that wants to start another one hands it to the scheduler (proactor_spawn); resuming from
 * inside a coroutine would overwrite the loop's saved stack pointer.
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>

typedef struct coro {
    void   *sp;               /* saved stack pointer while suspended                  */
    void   *stack;            /* mmap base; the lowest page is the guard              */
    size_t  size;             /* mapping size, guard included                         */
    void  (*fn)(void *);
    void   *arg;
    bool    done;             /* fn returned; the next resume-return frees the stack  */
    struct coro *next;        /* scheduler's ready-list link                          */
} coro_t;

/* Allocate a stack and forge its first frame. The descriptor lives at the top of that stack. */
coro_t *coro_create(void (*fn)(void *), void *arg, size_t stack_bytes);

/* Loop only. Run c until it yields; if it finished, its stack is unmapped before returning. */
void coro_resume(coro_t *c);

/* Coroutine only. Back to the loop; returns when the loop resumes this coroutine again. */
void coro_yield(void);

/* The running coroutine, NULL on the loop stack. */
coro_t *coro_current(void);
