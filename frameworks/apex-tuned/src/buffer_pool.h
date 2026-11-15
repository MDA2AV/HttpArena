#pragma once

#include <stdbool.h>
#include <stddef.h>

#define BUFFER_POOL_SLAB_SIZE 16384
#define BUFFER_POOL_DEFAULT_CAPACITY 2048

typedef struct buffer_pool_s {
    char **slabs;
    size_t count;
    size_t capacity;
    size_t total_allocated;
} buffer_pool_t;

bool buffer_pool_init(buffer_pool_t *pool, size_t initial_capacity);
char *buffer_pool_acquire(buffer_pool_t *pool);
void buffer_pool_release(buffer_pool_t *pool, char *buffer);
void buffer_pool_destroy(buffer_pool_t *pool);
