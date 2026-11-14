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

static inline void swap_entries(timer_entry_t *a, timer_entry_t *b) {
    timer_entry_t tmp = *a;
    *a = *b;
    *b = tmp;
}

bool timer_heap_push(timer_heap_t *th, uint64_t expire_at_ms, void *conn_ptr, uint32_t conn_gen, int64_t delay_ms) {
    if (th->count >= th->capacity) {
        size_t new_cap = th->capacity * 2;
        timer_entry_t *re = realloc(th->entries, sizeof(timer_entry_t) * new_cap);
        if (!re) return false;
        th->entries = re;
        th->capacity = new_cap;
    }

    size_t i = th->count++;
    th->entries[i] = (timer_entry_t){
        .expire_at_ms = expire_at_ms,
        .conn_ptr = conn_ptr,
        .conn_gen = conn_gen,
        .delay_ms = delay_ms
    };

    while (i > 0) {
        size_t parent = (i - 1) / 2;
        if (th->entries[parent].expire_at_ms <= th->entries[i].expire_at_ms) {
            break;
        }
        swap_entries(&th->entries[parent], &th->entries[i]);
        i = parent;
    }

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

    th->entries[0] = th->entries[th->count];
    size_t i = 0;
    while (true) {
        size_t left = 2 * i + 1;
        size_t right = 2 * i + 2;
        size_t smallest = i;

        if (left < th->count && th->entries[left].expire_at_ms < th->entries[smallest].expire_at_ms) {
            smallest = left;
        }
        if (right < th->count && th->entries[right].expire_at_ms < th->entries[smallest].expire_at_ms) {
            smallest = right;
        }
        if (smallest == i) break;

        swap_entries(&th->entries[i], &th->entries[smallest]);
        i = smallest;
    }

    return true;
}

int timer_heap_next_timeout_ms(const timer_heap_t *th, uint64_t now_ms) {
    if (th->count == 0) return -1;
    uint64_t next_ms = th->entries[0].expire_at_ms;
    if (next_ms <= now_ms) return 0;
    uint64_t diff = next_ms - now_ms;
    return (diff > 1000) ? 1000 : (int)diff;
}
