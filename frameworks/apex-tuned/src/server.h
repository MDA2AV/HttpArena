#pragma once

#include "common.h"
#include "http.h"
#include "router.h"
#include "dataset.h"
#include "timer.h"
#include <openssl/ssl.h>

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
    char inline_read_buf[16384];

    char *pending_write;
    size_t pending_write_len;
    size_t pending_write_sent;

    char scratch[64];

    bool parked_in_timer;
    uint64_t timer_expire_us;
    int64_t timer_val_ms;

    bool keep_alive;
    bool closing;

    uint64_t last_active_ms;
    conn_t *active_prev;
    conn_t *active_next;

    conn_t *next_free;
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
    timer_heap_t timers;
    conn_t *free_conns;
    conn_t *active_head;
    conn_t *active_tail;
    uint64_t last_trim_ms;

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
