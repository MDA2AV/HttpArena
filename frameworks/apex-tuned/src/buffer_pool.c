#include "buffer_pool.h"

#include <stdlib.h>
#include <string.h>

bool buffer_pool_init(buffer_pool_t *pool, size_t initial_capacity) {
    if (initial_capacity == 0) {
        initial_capacity = BUFFER_POOL_DEFAULT_CAPACITY;
    }

    pool->slabs = malloc(sizeof(char *) * initial_capacity);
    if (!pool->slabs) {
        return false;
    }

    pool->count = 0;
    pool->capacity = initial_capacity;
    pool->total_allocated = 0;

    for (size_t slab_index = 0; slab_index < initial_capacity; slab_index++) {
        char *buffer = malloc(BUFFER_POOL_SLAB_SIZE);
        if (!buffer) {
            buffer_pool_destroy(pool);
            return false;
        }
        pool->slabs[pool->count++] = buffer;
        pool->total_allocated++;
    }

    return true;
}

char *buffer_pool_acquire(buffer_pool_t *pool) {
    if (pool->count > 0) {
        return pool->slabs[--pool->count];
    }

    char *fallback_buffer = malloc(BUFFER_POOL_SLAB_SIZE);
    if (fallback_buffer) {
        pool->total_allocated++;
    }
    return fallback_buffer;
}

void buffer_pool_release(buffer_pool_t *pool, char *buffer) {
    if (!buffer) {
        return;
    }

    if (pool->count < pool->capacity) {
        pool->slabs[pool->count++] = buffer;
        return;
    }

    free(buffer);
    if (pool->total_allocated > 0) {
        pool->total_allocated--;
    }
}

void buffer_pool_destroy(buffer_pool_t *pool) {
    if (!pool->slabs) {
        return;
    }

    for (size_t slab_index = 0; slab_index < pool->count; slab_index++) {
        free(pool->slabs[slab_index]);
    }

    free(pool->slabs);
    pool->slabs = NULL;
    pool->count = 0;
    pool->capacity = 0;
    pool->total_allocated = 0;
}
