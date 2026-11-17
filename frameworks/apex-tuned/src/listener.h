#pragma once

#include "server.h"

int setup_listener_socket(int port);
void set_client_socket_options(int client_fd);

void handle_accept_http1(worker_t *worker);
void handle_accept_tls(worker_t *worker);
void handle_accept_h2c(worker_t *worker);
void handle_accept_h2(worker_t *worker);
