#include "timer.h"
#include "handlers.h"
#include "server.h"

#include <string.h>

void timer_wheel_init(timer_wheel_t *wheel, uint64_t initial_time_ms) {
    memset(wheel->buckets, 0, sizeof(wheel->buckets));
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
    wheel->active_count = 0;
}

void timer_wheel_schedule(timer_wheel_t *wheel, conn_t *connection, uint64_t expire_ms) {
    if (connection->parked_in_timer) {
        timer_wheel_cancel(wheel, connection);
    }

    connection->parked_in_timer = true;
    connection->timer_expire_ms = expire_ms;

    size_t slot_index = (size_t)(expire_ms & TIMER_WHEEL_MASK);
    connection->timer_prev = NULL;
    connection->timer_next = wheel->buckets[slot_index];
    if (wheel->buckets[slot_index] != NULL) {
        wheel->buckets[slot_index]->timer_prev = connection;
    }
    wheel->buckets[slot_index] = connection;
    wheel->active_count++;
}

void timer_wheel_cancel(timer_wheel_t *wheel, conn_t *connection) {
    if (!connection->parked_in_timer) {
        return;
    }

    size_t slot_index = (size_t)(connection->timer_expire_ms & TIMER_WHEEL_MASK);
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
}

void timer_wheel_process_expired(timer_wheel_t *wheel, worker_t *worker, uint64_t current_time_ms) {
    if (wheel->active_count == 0) {
        wheel->current_wheel_ms = current_time_ms;
        return;
    }

    if (current_time_ms < wheel->current_wheel_ms) {
        return;
    }

    if (current_time_ms - wheel->current_wheel_ms >= TIMER_WHEEL_SIZE) {
        if (current_time_ms >= (TIMER_WHEEL_SIZE - 1)) {
            wheel->current_wheel_ms = current_time_ms - (TIMER_WHEEL_SIZE - 1);
        } else {
            wheel->current_wheel_ms = 0;
        }
    }

    while (wheel->current_wheel_ms <= current_time_ms) {
        size_t slot_index = (size_t)(wheel->current_wheel_ms & TIMER_WHEEL_MASK);
        conn_t *current_conn = wheel->buckets[slot_index];
        wheel->buckets[slot_index] = NULL;
        conn_t *unexpired_head = NULL;

        while (current_conn != NULL) {
            conn_t *next_conn = current_conn->timer_next;
            if (current_conn->timer_expire_ms <= current_time_ms) {
                current_conn->timer_prev = NULL;
                current_conn->timer_next = NULL;
                current_conn->parked_in_timer = false;
                if (wheel->active_count > 0) {
                    wheel->active_count--;
                }
                handle_timer_expiration(worker, current_conn, current_conn->timer_val_ms);
            } else {
                current_conn->timer_prev = NULL;
                current_conn->timer_next = unexpired_head;
                if (unexpired_head != NULL) {
                    unexpired_head->timer_prev = current_conn;
                }
                unexpired_head = current_conn;
            }
            current_conn = next_conn;
        }

        if (unexpired_head != NULL) {
            if (wheel->buckets[slot_index] == NULL) {
                wheel->buckets[slot_index] = unexpired_head;
            } else {
                conn_t *tail = unexpired_head;
                while (tail->timer_next != NULL) {
                    tail = tail->timer_next;
                }
                tail->timer_next = wheel->buckets[slot_index];
                wheel->buckets[slot_index]->timer_prev = tail;
                wheel->buckets[slot_index] = unexpired_head;
            }
        }

        wheel->current_wheel_ms++;
    }
}

int timer_wheel_next_timeout_ms(const timer_wheel_t *wheel, uint64_t current_time_ms) {
    if (wheel->active_count == 0) {
        return 1000;
    }
    if (wheel->current_wheel_ms <= current_time_ms) {
        return 0;
    }

    uint64_t min_timeout = 1000;
    for (size_t offset = 1; offset < min_timeout && offset < TIMER_WHEEL_SIZE; offset++) {
        size_t slot_index = (size_t)((current_time_ms + offset) & TIMER_WHEEL_MASK);
        conn_t *connection = wheel->buckets[slot_index];
        while (connection != NULL) {
            if (connection->timer_expire_ms > current_time_ms) {
                uint64_t diff = connection->timer_expire_ms - current_time_ms;
                if (diff < min_timeout) {
                    min_timeout = diff;
                }
            }
            connection = connection->timer_next;
        }
    }

    return (int)min_timeout;
}
