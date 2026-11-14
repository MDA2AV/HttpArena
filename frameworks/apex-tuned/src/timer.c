#include "timer.h"

void timer_heap_init(timer_heap_t *th, size_t initial_cap) {
    if (initial_cap < 64) initial_cap = 64;
    th->entries = malloc(sizeof(timer_entry_t) * initial_cap);
    th->count = 0;
    th->capacity = initial_cap;
}

void timer_heap_destroy(timer_heap_t *th) {
    if (th->entries) {
        free(th->entries);
        th->entries = NULL;
    }
    th->count = 0;
    th->capacity = 0;
}

bool timer_heap_push(timer_heap_t *th, uint64_t expire_at_us, void *conn_ptr, uint32_t conn_gen, int64_t delay_ms) {
    if (th->count >= th->capacity) {
        size_t new_cap = th->capacity * 2;
        timer_entry_t *re = realloc(th->entries, sizeof(timer_entry_t) * new_cap);
        if (!re) return false;
        th->entries = re;
        th->capacity = new_cap;
    }

    size_t i = th->count++;
    timer_entry_t item = {
        .expire_at_us = expire_at_us,
        .conn_ptr = conn_ptr,
        .conn_gen = conn_gen,
        .delay_ms = delay_ms
    };

    while (i > 0) {
        size_t parent = (i - 1) / 2;
        if (th->entries[parent].expire_at_us <= item.expire_at_us) {
            break;
        }
        th->entries[i] = th->entries[parent];
        i = parent;
    }
    th->entries[i] = item;

    return true;
}

bool timer_heap_peek(const timer_heap_t *th, timer_entry_t *out) {
    if (th->count == 0) return false;
    *out = th->entries[0];
    return true;
}

bool timer_heap_pop(timer_heap_t *th, timer_entry_t *out) {
    if (th->count == 0) return false;
    *out = th->entries[0];

    th->count--;
    if (th->count == 0) return true;

    timer_entry_t item = th->entries[th->count];
    size_t i = 0;
    while (true) {
        size_t left = 2 * i + 1;
        size_t right = 2 * i + 2;
        size_t smallest = i;

        if (left < th->count && th->entries[left].expire_at_us < item.expire_at_us) {
            smallest = left;
        }
        if (right < th->count && th->entries[right].expire_at_us < (smallest == i ? item.expire_at_us : th->entries[smallest].expire_at_us)) {
            smallest = right;
        }
        if (smallest == i) break;

        th->entries[i] = th->entries[smallest];
        i = smallest;
    }
    th->entries[i] = item;

    return true;
}

int64_t timer_heap_next_timeout_us(const timer_heap_t *th, uint64_t now_us) {
    if (th->count == 0) return -1;
    uint64_t next_us = th->entries[0].expire_at_us;
    if (next_us <= now_us) return 0;
    return (int64_t)(next_us - now_us);
}
