#include "timer.h"
#include "handlers.h"
#include "server.h"

#include <string.h>

_Static_assert(TIMER_WHEEL_SIZE == TIMER_WHEEL_WORD_BITS * TIMER_WHEEL_WORD_COUNT,
               "timer wheel bitmap must cover every bucket");
_Static_assert(TIMER_WHEEL_WORD_COUNT <= TIMER_WHEEL_WORD_BITS,
               "timer wheel summary must fit in one word");

static inline void timer_bucket_mark_occupied(timer_wheel_t *wheel, size_t bucket_index) {
    size_t word_index = bucket_index / TIMER_WHEEL_WORD_BITS;
    uint64_t bucket_bit = UINT64_C(1) << (bucket_index % TIMER_WHEEL_WORD_BITS);
    wheel->occupied_buckets[word_index] |= bucket_bit;
    wheel->occupied_words |= UINT64_C(1) << word_index;
}

static inline void timer_bucket_mark_empty(timer_wheel_t *wheel, size_t bucket_index) {
    size_t word_index = bucket_index / TIMER_WHEEL_WORD_BITS;
    uint64_t bucket_bit = UINT64_C(1) << (bucket_index % TIMER_WHEEL_WORD_BITS);
    wheel->occupied_buckets[word_index] &= ~bucket_bit;
    if (wheel->occupied_buckets[word_index] == 0) {
        wheel->occupied_words &= ~(UINT64_C(1) << word_index);
    }
}

static void timer_bucket_recompute_minimum(timer_wheel_t *wheel, size_t bucket_index) {
    uint64_t minimum_expire_ms = UINT64_MAX;
    for (conn_t *connection = wheel->buckets[bucket_index]; connection != NULL;
         connection = connection->timer_next) {
        if (connection->timer_expire_ms < minimum_expire_ms) {
            minimum_expire_ms = connection->timer_expire_ms;
        }
    }

    wheel->bucket_min_expire_ms[bucket_index] = minimum_expire_ms;
    if (minimum_expire_ms == UINT64_MAX) {
        timer_bucket_mark_empty(wheel, bucket_index);
    } else {
        timer_bucket_mark_occupied(wheel, bucket_index);
    }
}

static void timer_wheel_recompute_next_expiration(timer_wheel_t *wheel) {
    uint64_t minimum_expire_ms = UINT64_MAX;
    uint64_t occupied_words = wheel->occupied_words;
    while (occupied_words != 0) {
        size_t word_index = (size_t)__builtin_ctzll(occupied_words);
        uint64_t occupied_buckets = wheel->occupied_buckets[word_index];
        while (occupied_buckets != 0) {
            size_t bit_index = (size_t)__builtin_ctzll(occupied_buckets);
            size_t bucket_index = word_index * TIMER_WHEEL_WORD_BITS + bit_index;
            if (wheel->bucket_min_expire_ms[bucket_index] < minimum_expire_ms) {
                minimum_expire_ms = wheel->bucket_min_expire_ms[bucket_index];
            }
            occupied_buckets &= occupied_buckets - 1;
        }
        occupied_words &= occupied_words - 1;
    }
    wheel->next_expire_ms = minimum_expire_ms;
}

void timer_wheel_init(timer_wheel_t *wheel, uint64_t initial_time_ms) {
    memset(wheel->buckets, 0, sizeof(wheel->buckets));
    memset(wheel->bucket_min_expire_ms, 0xff, sizeof(wheel->bucket_min_expire_ms));
    memset(wheel->occupied_buckets, 0, sizeof(wheel->occupied_buckets));
    wheel->occupied_words = 0;
    wheel->next_expire_ms = UINT64_MAX;
    wheel->current_wheel_ms = initial_time_ms;
    wheel->active_count = 0;
}

void timer_wheel_destroy(timer_wheel_t *wheel) {
    for (size_t bucket_index = 0; bucket_index < TIMER_WHEEL_SIZE; bucket_index++) {
        conn_t *current_conn = wheel->buckets[bucket_index];
        while (current_conn != NULL) {
            conn_t *next_conn = current_conn->timer_next;
            current_conn->timer_prev = NULL;
            current_conn->timer_next = NULL;
            current_conn->parked_in_timer = false;
            current_conn = next_conn;
        }
        wheel->buckets[bucket_index] = NULL;
    }
    memset(wheel->bucket_min_expire_ms, 0xff, sizeof(wheel->bucket_min_expire_ms));
    memset(wheel->occupied_buckets, 0, sizeof(wheel->occupied_buckets));
    wheel->occupied_words = 0;
    wheel->next_expire_ms = UINT64_MAX;
    wheel->active_count = 0;
}

void timer_wheel_schedule(timer_wheel_t *wheel, conn_t *connection, uint64_t expire_ms) {
    if (connection->parked_in_timer) {
        timer_wheel_cancel(wheel, connection);
    }

    connection->parked_in_timer = true;
    connection->timer_expire_ms = expire_ms;

    size_t slot_index = (size_t)(expire_ms & TIMER_WHEEL_MASK);
    bool bucket_was_empty = wheel->buckets[slot_index] == NULL;
    connection->timer_prev = NULL;
    connection->timer_next = wheel->buckets[slot_index];
    if (wheel->buckets[slot_index] != NULL) {
        wheel->buckets[slot_index]->timer_prev = connection;
    }
    wheel->buckets[slot_index] = connection;
    if (bucket_was_empty) {
        timer_bucket_mark_occupied(wheel, slot_index);
        wheel->bucket_min_expire_ms[slot_index] = expire_ms;
    } else if (expire_ms < wheel->bucket_min_expire_ms[slot_index]) {
        wheel->bucket_min_expire_ms[slot_index] = expire_ms;
    }
    if (expire_ms < wheel->next_expire_ms) {
        wheel->next_expire_ms = expire_ms;
    }
    wheel->active_count++;
}

void timer_wheel_cancel(timer_wheel_t *wheel, conn_t *connection) {
    if (!connection->parked_in_timer) {
        return;
    }

    uint64_t cancelled_expire_ms = connection->timer_expire_ms;
    size_t slot_index = (size_t)(cancelled_expire_ms & TIMER_WHEEL_MASK);
    if (connection->timer_prev != NULL) {
        connection->timer_prev->timer_next = connection->timer_next;
    } else if (wheel->buckets[slot_index] == connection) {
        wheel->buckets[slot_index] = connection->timer_next;
    }

    if (connection->timer_next != NULL) {
        connection->timer_next->timer_prev = connection->timer_prev;
    }

    connection->timer_prev = NULL;
    connection->timer_next = NULL;
    connection->parked_in_timer = false;
    if (wheel->active_count > 0) {
        wheel->active_count--;
    }

    if (wheel->buckets[slot_index] == NULL) {
        wheel->bucket_min_expire_ms[slot_index] = UINT64_MAX;
        timer_bucket_mark_empty(wheel, slot_index);
    } else if (cancelled_expire_ms == wheel->bucket_min_expire_ms[slot_index]) {
        timer_bucket_recompute_minimum(wheel, slot_index);
    }

    if (wheel->active_count == 0) {
        wheel->next_expire_ms = UINT64_MAX;
    } else if (cancelled_expire_ms == wheel->next_expire_ms &&
               wheel->bucket_min_expire_ms[slot_index] != cancelled_expire_ms) {
        timer_wheel_recompute_next_expiration(wheel);
    }
}

void timer_wheel_process_expired(timer_wheel_t *wheel, worker_t *worker, uint64_t current_time_ms) {
    if (wheel->active_count == 0) {
        wheel->current_wheel_ms = current_time_ms;
        return;
    }

    if (current_time_ms < wheel->current_wheel_ms) {
        return;
    }

    wheel->current_wheel_ms = current_time_ms;
    while (wheel->active_count > 0 && wheel->next_expire_ms <= current_time_ms) {
        size_t slot_index = (size_t)(wheel->next_expire_ms & TIMER_WHEEL_MASK);
        conn_t *current_conn = wheel->buckets[slot_index];
        wheel->buckets[slot_index] = NULL;
        wheel->bucket_min_expire_ms[slot_index] = UINT64_MAX;
        timer_bucket_mark_empty(wheel, slot_index);

        conn_t *unexpired_head = NULL;
        conn_t *unexpired_tail = NULL;

        while (current_conn != NULL) {
            conn_t *next_conn = current_conn->timer_next;
            if (current_conn->timer_expire_ms <= current_time_ms) {
                current_conn->timer_prev = NULL;
                current_conn->timer_next = NULL;
                current_conn->parked_in_timer = false;
                if (wheel->active_count > 0) {
                    wheel->active_count--;
                }
                handle_timer_expiration(worker, current_conn, current_conn->timer_val_ms, current_time_ms);
            } else {
                current_conn->timer_prev = unexpired_tail;
                current_conn->timer_next = NULL;
                if (unexpired_tail != NULL) {
                    unexpired_tail->timer_next = current_conn;
                } else {
                    unexpired_head = current_conn;
                }
                unexpired_tail = current_conn;
            }
            current_conn = next_conn;
        }

        if (unexpired_head != NULL) {
            if (wheel->buckets[slot_index] != NULL) {
                unexpired_tail->timer_next = wheel->buckets[slot_index];
                wheel->buckets[slot_index]->timer_prev = unexpired_tail;
            }
            wheel->buckets[slot_index] = unexpired_head;
        }

        if (wheel->buckets[slot_index] != NULL) {
            timer_bucket_recompute_minimum(wheel, slot_index);
        }
        if (wheel->active_count == 0) {
            wheel->next_expire_ms = UINT64_MAX;
        } else {
            timer_wheel_recompute_next_expiration(wheel);
        }
    }
}

int timer_wheel_next_timeout_ms(const timer_wheel_t *wheel, uint64_t current_time_ms) {
    if (wheel->active_count == 0) {
        return 1000;
    }
    if (wheel->next_expire_ms <= current_time_ms) {
        return 0;
    }

    uint64_t timeout_ms = wheel->next_expire_ms - current_time_ms;
    return timeout_ms < 1000 ? (int)timeout_ms : 1000;
}
