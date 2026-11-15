#include "timer.h"

void timer_heap_init(timer_heap_t *heap, size_t initial_capacity) {
    if (initial_capacity < 64) {
        initial_capacity = 64;
    }
    heap->entries = malloc(sizeof(timer_entry_t) * initial_capacity);
    heap->count = 0;
    heap->capacity = initial_capacity;
}

void timer_heap_destroy(timer_heap_t *heap) {
    if (heap->entries) {
        free(heap->entries);
        heap->entries = NULL;
    }
    heap->count = 0;
    heap->capacity = 0;
}

bool timer_heap_push(timer_heap_t *heap, uint64_t expire_at_us, void *conn_ptr, uint32_t conn_gen, int64_t delay_ms) {
    if (heap->count >= heap->capacity) {
        size_t new_capacity = heap->capacity * 2;
        timer_entry_t *reallocated_entries = realloc(heap->entries, sizeof(timer_entry_t) * new_capacity);
        if (!reallocated_entries) {
            return false;
        }
        heap->entries = reallocated_entries;
        heap->capacity = new_capacity;
    }

    size_t current_index = heap->count++;
    timer_entry_t item = {
        .expire_at_us = expire_at_us, .conn_ptr = conn_ptr, .conn_gen = conn_gen, .delay_ms = delay_ms};

    while (current_index > 0) {
        size_t parent_index = (current_index - 1) / 2;
        if (heap->entries[parent_index].expire_at_us <= item.expire_at_us) {
            break;
        }
        heap->entries[current_index] = heap->entries[parent_index];
        current_index = parent_index;
    }
    heap->entries[current_index] = item;

    return true;
}

bool timer_heap_peek(const timer_heap_t *heap, timer_entry_t *out_entry) {
    if (heap->count == 0) {
        return false;
    }
    *out_entry = heap->entries[0];
    return true;
}

bool timer_heap_pop(timer_heap_t *heap, timer_entry_t *out_entry) {
    if (heap->count == 0) {
        return false;
    }
    *out_entry = heap->entries[0];

    heap->count--;
    if (heap->count == 0) {
        return true;
    }

    timer_entry_t item = heap->entries[heap->count];
    size_t current_index = 0;
    while (true) {
        size_t left_child_index = 2 * current_index + 1;
        size_t right_child_index = 2 * current_index + 2;
        size_t smallest_index = current_index;

        if (left_child_index < heap->count && heap->entries[left_child_index].expire_at_us < item.expire_at_us) {
            smallest_index = left_child_index;
        }
        if (right_child_index < heap->count &&
            heap->entries[right_child_index].expire_at_us <
                (smallest_index == current_index ? item.expire_at_us : heap->entries[smallest_index].expire_at_us)) {
            smallest_index = right_child_index;
        }
        if (smallest_index == current_index) {
            break;
        }

        heap->entries[current_index] = heap->entries[smallest_index];
        current_index = smallest_index;
    }
    heap->entries[current_index] = item;

    return true;
}

int64_t timer_heap_next_timeout_us(const timer_heap_t *heap, uint64_t current_time_us) {
    if (heap->count == 0) {
        return -1;
    }
    uint64_t next_expire_us = heap->entries[0].expire_at_us;
    if (next_expire_us <= current_time_us) {
        return 0;
    }
    return (int64_t)(next_expire_us - current_time_us);
}
