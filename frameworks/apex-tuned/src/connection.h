#pragma once

#include "server.h"

conn_t *alloc_conn(worker_t *worker, int client_fd, bool is_tls, SSL *ssl_session);
void close_conn(worker_t *worker, conn_t *connection);
void conn_list_insert_tail(worker_t *worker, conn_t *connection);
void conn_list_remove(worker_t *worker, conn_t *connection);
void conn_touch(worker_t *worker, conn_t *connection, uint64_t current_time_ms);
void trim_inactive_connections(worker_t *worker, uint64_t current_time_ms);
void conn_mark_stalled(worker_t *worker, conn_t *connection);
void conn_unmark_stalled(worker_t *worker, conn_t *connection);
