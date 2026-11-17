#pragma once

#include "server.h"

extern volatile sig_atomic_t g_running;

int worker_init(worker_t *worker, int id, int cpu_id, SSL_CTX *ssl_ctx, SSL_CTX *ssl_ctx_h2, int port_h1, int port_tls,
                int port_h2c, int port_h2);
void process_requests(worker_t *worker, conn_t *connection);
void *worker_thread_main(void *thread_argument);
