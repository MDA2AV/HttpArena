#pragma once

#include "common.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct conn_s conn_t;
typedef struct worker_s worker_t;

#define TIMER_WHEEL_SIZE 4096
#define TIMER_WHEEL_MASK (TIMER_WHEEL_SIZE - 1)
#define TIMER_WHEEL_WORD_BITS 64
#define TIMER_WHEEL_WORD_COUNT (TIMER_WHEEL_SIZE / TIMER_WHEEL_WORD_BITS)

typedef struct timer_wheel_s {
    conn_t *buckets[TIMER_WHEEL_SIZE];
    uint64_t bucket_min_expire_ms[TIMER_WHEEL_SIZE];
    uint64_t occupied_buckets[TIMER_WHEEL_WORD_COUNT];
    uint64_t occupied_words;
    uint64_t next_expire_ms;
    uint64_t current_wheel_ms;
    size_t active_count;
} timer_wheel_t;

void timer_wheel_init(timer_wheel_t *wheel, uint64_t initial_time_ms);
void timer_wheel_destroy(timer_wheel_t *wheel);
void timer_wheel_schedule(timer_wheel_t *wheel, conn_t *connection, uint64_t expire_ms);
void timer_wheel_cancel(timer_wheel_t *wheel, conn_t *connection);
void timer_wheel_process_expired(timer_wheel_t *wheel, worker_t *worker, uint64_t current_time_ms);
int timer_wheel_next_timeout_ms(const timer_wheel_t *wheel, uint64_t current_time_ms);
