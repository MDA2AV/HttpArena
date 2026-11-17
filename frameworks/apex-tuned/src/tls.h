#pragma once

#include "common.h"
#include <openssl/ssl.h>
#include <openssl/err.h>

SSL_CTX *tls_init_server_ctx(const char *cert_file, const char *key_file, bool alpn_h2);
void tls_free_server_ctx(SSL_CTX *ctx);
