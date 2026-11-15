#pragma once

#include "buffer_pool.h"
#include "common.h"
#include "dataset.h"
#include "http.h"
#include "router.h"
#include "timer.h"

#include <openssl/ssl.h>
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define MAX_CONNECTIONS_PER_WORKER 65536
#define MAX_EPOLL_EVENTS 512
#define WRITE_BUF_SIZE (512 * 1024)
#define IDLE_TIMEOUT_MS 15000
#define TRIM_INTERVAL_MS 1000

typedef struct conn_s conn_t;
typedef struct worker_s worker_t;

struct conn_s {
    int fd;
    uint32_t gen;
    bool is_tls;
    SSL *ssl;
    bool tls_handshake_done;

    bool is_h2;
    void *h2;

    char *read_buf;
    size_t read_cap;
    size_t read_pos;
    bool has_pooled_buffer;

    char *pending_write;
    size_t pending_write_len;
    size_t pending_write_sent;

    bool parked_in_timer;
    uint64_t timer_expire_ms;
    int64_t timer_val_ms;
    conn_t *timer_prev;
    conn_t *timer_next;

    bool keep_alive;
    bool closing;

    bool in_stalled_list;
    uint64_t stalled_since_ms;
    conn_t *stalled_prev;
    conn_t *stalled_next;

    uint64_t last_active_ms;
    conn_t *active_prev;
    conn_t *active_next;

    conn_t *next_free;
    char scratch[64];
};

struct worker_s {
    int id;
    int cpu_id;
    pthread_t thread;
    int epoll_fd;
    int listen_h1_fd;
    int listen_tls_fd;
    int listen_h2c_fd;
    int listen_h2_fd;
    SSL_CTX *ssl_ctx;
    SSL_CTX *ssl_ctx_h2;
    router_t router;
    worker_compress_t compress;
    timer_wheel_t timers;
    buffer_pool_t buffer_pool;
    conn_t *free_conns;
    conn_t *active_head;
    conn_t *active_tail;
    conn_t *stalled_head;
    conn_t *stalled_tail;
    uint64_t last_trim_ms;
    uint64_t last_malloc_trim_ms;

    int token_h1;
    int token_tls;
    int token_h2c;
    int token_h2;

    size_t h2_write_pos;
    char write_buf[WRITE_BUF_SIZE];
    char chunk_buf[128 * 1024];
};

void close_conn(worker_t *worker, conn_t *connection);
void flush_data(worker_t *worker, conn_t *connection, const char *data, size_t length);
bool flush_pending_write(worker_t *worker, conn_t *connection);
