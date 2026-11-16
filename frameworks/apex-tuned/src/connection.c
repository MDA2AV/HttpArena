#include "connection.h"
#include "h2.h"

#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <unistd.h>
#if defined(__linux__) && defined(__GLIBC__)
#include <malloc.h>
#endif

void conn_list_insert_tail(worker_t *worker, conn_t *connection) {
    connection->active_next = NULL;
    connection->active_prev = worker->active_tail;
    if (worker->active_tail) {
        worker->active_tail->active_next = connection;
    } else {
        worker->active_head = connection;
    }
    worker->active_tail = connection;
}

void conn_list_remove(worker_t *worker, conn_t *connection) {
    if (connection->active_prev) {
        connection->active_prev->active_next = connection->active_next;
    }
    if (worker->active_head == connection) {
        worker->active_head = connection->active_next;
    }

    if (connection->active_next) {
        connection->active_next->active_prev = connection->active_prev;
    }
    if (worker->active_tail == connection) {
        worker->active_tail = connection->active_prev;
    }

    connection->active_prev = NULL;
    connection->active_next = NULL;
}

void conn_touch(worker_t *worker, conn_t *connection, uint64_t current_time_ms) {
    (void)worker;
    connection->last_active_ms = current_time_ms;
}

conn_t *alloc_conn(worker_t *worker, int client_fd, bool is_tls, SSL *ssl_session) {
    conn_t *connection = worker->free_conns;
    if (connection) {
        worker->free_conns = connection->next_free;
    } else {
        connection = calloc(1, sizeof(conn_t));
        if (!connection) {
            return NULL;
        }
    }

    connection->fd = client_fd;
    connection->gen++;
    connection->is_tls = is_tls;
    connection->ssl = ssl_session;
    connection->tls_handshake_done = false;
    connection->read_buf = NULL;
    connection->read_cap = 0;
    connection->read_pos = 0;
    connection->has_pooled_buffer = false;
    connection->request_started_ms = 0;
    connection->pending_write = NULL;
    connection->pending_write_len = 0;
    connection->pending_write_sent = 0;
    connection->is_h2 = false;
    connection->h2 = NULL;
    connection->parked_in_timer = false;
    connection->timer_prev = NULL;
    connection->timer_next = NULL;
    connection->timer_expire_ms = 0;
    connection->keep_alive = true;
    connection->closing = false;
    connection->next_free = NULL;
    connection->active_prev = NULL;
    connection->active_next = NULL;
    connection->in_stalled_list = false;
    connection->stalled_since_ms = 0;
    connection->stalled_prev = NULL;
    connection->stalled_next = NULL;
    connection->last_active_ms = clock_monotonic_ms();

    conn_list_insert_tail(worker, connection);
    return connection;
}

void conn_mark_stalled(worker_t *worker, conn_t *connection) {
    if (connection->in_stalled_list) {
        return;
    }
    connection->in_stalled_list = true;
    connection->stalled_since_ms = clock_monotonic_ms();
    connection->stalled_next = NULL;
    connection->stalled_prev = worker->stalled_tail;
    if (worker->stalled_tail) {
        worker->stalled_tail->stalled_next = connection;
    } else {
        worker->stalled_head = connection;
    }
    worker->stalled_tail = connection;
}

void conn_unmark_stalled(worker_t *worker, conn_t *connection) {
    if (!connection->in_stalled_list) {
        return;
    }
    if (connection->stalled_prev) {
        connection->stalled_prev->stalled_next = connection->stalled_next;
    } else if (worker->stalled_head == connection) {
        worker->stalled_head = connection->stalled_next;
    }

    if (connection->stalled_next) {
        connection->stalled_next->stalled_prev = connection->stalled_prev;
    } else if (worker->stalled_tail == connection) {
        worker->stalled_tail = connection->stalled_prev;
    }

    connection->in_stalled_list = false;
    connection->stalled_since_ms = 0;
    connection->stalled_prev = NULL;
    connection->stalled_next = NULL;
}

void close_conn(worker_t *worker, conn_t *connection) {
    conn_list_remove(worker, connection);
    conn_unmark_stalled(worker, connection);

    if (connection->parked_in_timer) {
        timer_wheel_cancel(&worker->timers, connection);
    }

    if (connection->is_h2) {
        h2_connection_destroy(connection);
        connection->is_h2 = false;
    }

    if (connection->fd >= 0) {
        epoll_ctl(worker->epoll_fd, EPOLL_CTL_DEL, connection->fd, NULL);
        close(connection->fd);
        connection->fd = -1;
    }

    if (connection->ssl) {
        SSL_free(connection->ssl);
        connection->ssl = NULL;
    }

    if (connection->pending_write) {
        free(connection->pending_write);
        connection->pending_write = NULL;
    }

    if (connection->read_buf) {
        if (connection->has_pooled_buffer) {
            buffer_pool_release(&worker->buffer_pool, connection->read_buf);
        } else {
            free(connection->read_buf);
        }
        connection->read_buf = NULL;
        connection->has_pooled_buffer = false;
    }

    connection->read_cap = 0;
    connection->read_pos = 0;
    connection->pending_write_len = 0;
    connection->pending_write_sent = 0;
    connection->parked_in_timer = false;
    connection->timer_prev = NULL;
    connection->timer_next = NULL;
    connection->closing = false;
    connection->gen++;

    connection->next_free = worker->free_conns;
    worker->free_conns = connection;
}

void trim_inactive_connections(worker_t *worker, uint64_t current_time_ms) {
    if (current_time_ms - worker->last_trim_ms < TRIM_INTERVAL_MS) {
        return;
    }
    worker->last_trim_ms = current_time_ms;

    conn_t *stalled_curr = worker->stalled_head;
    while (stalled_curr) {
        conn_t *stalled_next = stalled_curr->stalled_next;
        if (current_time_ms - stalled_curr->stalled_since_ms > 5000) {
            close_conn(worker, stalled_curr);
        }
        stalled_curr = stalled_next;
    }

    conn_t *curr = worker->active_head;
    size_t iterations = 0;
    while (curr) {
        if (++iterations > MAX_CONNS_PER_WORKER) {
            break;
        }
        conn_t *next = curr->active_next;
        if (curr->parked_in_timer) {
            curr = next;
            continue;
        }

        if (curr->read_pos > 0 && curr->request_started_ms > 0 &&
            (current_time_ms - curr->request_started_ms > 5000)) {
            close_conn(worker, curr);
            curr = next;
            continue;
        }

        if (curr->read_pos == 0 && (current_time_ms - curr->last_active_ms > 5000)) {
            close_conn(worker, curr);
            curr = next;
            continue;
        }

        if (current_time_ms - curr->last_active_ms >= IDLE_TIMEOUT_MS) {
            close_conn(worker, curr);
        }
        curr = next;
    }

#if defined(__linux__) && defined(__GLIBC__)
    if (current_time_ms - worker->last_malloc_trim_ms > 5000) {
        malloc_trim(0);
        worker->last_malloc_trim_ms = current_time_ms;
    }
#endif
}
