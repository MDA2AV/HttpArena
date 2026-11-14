#pragma once

#include "common.h"

typedef struct {
    uint64_t expire_at_us;
    void    *conn_ptr;
    uint32_t conn_gen;
    int64_t  delay_ms;
} timer_entry_t;

typedef struct {
    timer_entry_t *entries;
    size_t         count;
    size_t         capacity;
} timer_heap_t;

void timer_heap_init(timer_heap_t *th, size_t initial_cap);
void timer_heap_destroy(timer_heap_t *th);
bool timer_heap_push(timer_heap_t *th, uint64_t expire_at_us, void *conn_ptr, uint32_t conn_gen, int64_t delay_ms);
bool timer_heap_peek(const timer_heap_t *th, timer_entry_t *out);
bool timer_heap_pop(timer_heap_t *th, timer_entry_t *out);
int64_t timer_heap_next_timeout_us(const timer_heap_t *th, uint64_t now_us);
