#include "listener.h"
#include "connection.h"
#include "h2.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <unistd.h>

void set_client_socket_options(int client_fd) {
    set_sock_opts(client_fd);
}

int setup_listener_socket(int port) {
    int listen_fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (listen_fd < 0) {
        return -1;
    }

    int enable_option = 1;
    setsockopt(listen_fd, SOL_SOCKET, SO_REUSEPORT, &enable_option, sizeof(enable_option));
    setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &enable_option, sizeof(enable_option));
    setsockopt(listen_fd, IPPROTO_TCP, TCP_NODELAY, &enable_option, sizeof(enable_option));
    setsockopt(listen_fd, IPPROTO_TCP, TCP_DEFER_ACCEPT, &enable_option, sizeof(enable_option));

    struct sockaddr_in socket_address;
    memset(&socket_address, 0, sizeof(socket_address));
    socket_address.sin_family = AF_INET;
    socket_address.sin_addr.s_addr = htonl(INADDR_ANY);
    socket_address.sin_port = htons((uint16_t)port);

    if (bind(listen_fd, (struct sockaddr *)&socket_address, sizeof(socket_address)) < 0) {
        close(listen_fd);
        return -1;
    }

    if (listen(listen_fd, 65535) < 0) {
        close(listen_fd);
        return -1;
    }

    return listen_fd;
}

void handle_accept_http1(worker_t *worker) {
    while (true) {
        int client_fd = accept4(worker->listen_h1_fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
        if (client_fd < 0) {
            break;
        }

        set_client_socket_options(client_fd);
        conn_t *connection = alloc_conn(worker, client_fd, false, NULL);
        if (!connection) {
            close(client_fd);
            continue;
        }

        struct epoll_event event = {.events = EPOLLIN | EPOLLRDHUP | EPOLLHUP | EPOLLERR,
                                    .data.ptr = connection};
        epoll_ctl(worker->epoll_fd, EPOLL_CTL_ADD, client_fd, &event);
    }
}

void handle_accept_tls(worker_t *worker) {
    while (true) {
        int client_fd = accept4(worker->listen_tls_fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
        if (client_fd < 0) {
            break;
        }

        set_client_socket_options(client_fd);
        SSL *ssl_session = SSL_new(worker->ssl_ctx);
        if (!ssl_session) {
            close(client_fd);
            continue;
        }
        SSL_set_fd(ssl_session, client_fd);
        SSL_set_accept_state(ssl_session);

        conn_t *connection = alloc_conn(worker, client_fd, true, ssl_session);
        if (!connection) {
            SSL_free(ssl_session);
            close(client_fd);
            continue;
        }

        struct epoll_event event = {.events = EPOLLIN | EPOLLOUT | EPOLLRDHUP | EPOLLHUP | EPOLLERR,
                                    .data.ptr = connection};
        epoll_ctl(worker->epoll_fd, EPOLL_CTL_ADD, client_fd, &event);
    }
}

void handle_accept_h2c(worker_t *worker) {
    while (true) {
        int client_fd = accept4(worker->listen_h2c_fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
        if (client_fd < 0) {
            break;
        }

        set_client_socket_options(client_fd);
        conn_t *connection = alloc_conn(worker, client_fd, false, NULL);
        if (!connection) {
            close(client_fd);
            continue;
        }

        connection->is_h2 = true;
        if (!h2_connection_init(connection, worker)) {
            close_conn(worker, connection);
            continue;
        }

        struct epoll_event event = {.events = EPOLLIN | EPOLLRDHUP | EPOLLHUP | EPOLLERR,
                                    .data.ptr = connection};
        epoll_ctl(worker->epoll_fd, EPOLL_CTL_ADD, client_fd, &event);
    }
}

void handle_accept_h2(worker_t *worker) {
    while (true) {
        int client_fd = accept4(worker->listen_h2_fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
        if (client_fd < 0) {
            break;
        }

        set_client_socket_options(client_fd);
        SSL *ssl_session = SSL_new(worker->ssl_ctx_h2);
        if (!ssl_session) {
            close(client_fd);
            continue;
        }
        SSL_set_fd(ssl_session, client_fd);
        SSL_set_accept_state(ssl_session);

        conn_t *connection = alloc_conn(worker, client_fd, true, ssl_session);
        if (!connection) {
            SSL_free(ssl_session);
            close(client_fd);
            continue;
        }

        struct epoll_event event = {.events = EPOLLIN | EPOLLOUT | EPOLLRDHUP | EPOLLHUP | EPOLLERR,
                                    .data.ptr = connection};
        epoll_ctl(worker->epoll_fd, EPOLL_CTL_ADD, client_fd, &event);
    }
}
