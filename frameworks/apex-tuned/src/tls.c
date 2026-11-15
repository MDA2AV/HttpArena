#include "tls.h"

static int alpn_select_http1_callback(SSL *ssl_handle, const unsigned char **selected_protocol_out,
                                      unsigned char *selected_protocol_length_out,
                                      const unsigned char *client_protocols, unsigned int client_protocols_length,
                                      void *user_data) {
    (void)ssl_handle;
    (void)user_data;

    for (unsigned int cursor_index = 0; cursor_index < client_protocols_length;) {
        unsigned char protocol_length = client_protocols[cursor_index++];
        if (cursor_index + protocol_length > client_protocols_length) {
            break;
        }

        if (protocol_length == 8 && memcmp(&client_protocols[cursor_index], "http/1.1", 8) == 0) {
            *selected_protocol_out = &client_protocols[cursor_index];
            *selected_protocol_length_out = protocol_length;
            return SSL_TLSEXT_ERR_OK;
        }

        cursor_index += protocol_length;
    }

    if (client_protocols_length > 0) {
        *selected_protocol_out = &client_protocols[1];
        *selected_protocol_length_out = client_protocols[0];
        return SSL_TLSEXT_ERR_OK;
    }

    return SSL_TLSEXT_ERR_NOACK;
}

static int alpn_select_http2_callback(SSL *ssl_handle, const unsigned char **selected_protocol_out,
                                      unsigned char *selected_protocol_length_out,
                                      const unsigned char *client_protocols, unsigned int client_protocols_length,
                                      void *user_data) {
    (void)ssl_handle;
    (void)user_data;

    /* First attempt: prioritize HTTP/2 */
    for (unsigned int cursor_index = 0; cursor_index < client_protocols_length;) {
        unsigned char protocol_length = client_protocols[cursor_index++];
        if (cursor_index + protocol_length > client_protocols_length) {
            break;
        }

        if (protocol_length == 2 && memcmp(&client_protocols[cursor_index], "h2", 2) == 0) {
            *selected_protocol_out = &client_protocols[cursor_index];
            *selected_protocol_length_out = protocol_length;
            return SSL_TLSEXT_ERR_OK;
        }

        cursor_index += protocol_length;
    }

    /* Second attempt: fallback to HTTP/1.1 */
    for (unsigned int cursor_index = 0; cursor_index < client_protocols_length;) {
        unsigned char protocol_length = client_protocols[cursor_index++];
        if (cursor_index + protocol_length > client_protocols_length) {
            break;
        }

        if (protocol_length == 8 && memcmp(&client_protocols[cursor_index], "http/1.1", 8) == 0) {
            *selected_protocol_out = &client_protocols[cursor_index];
            *selected_protocol_length_out = protocol_length;
            return SSL_TLSEXT_ERR_OK;
        }

        cursor_index += protocol_length;
    }

    if (client_protocols_length > 0) {
        *selected_protocol_out = &client_protocols[1];
        *selected_protocol_length_out = client_protocols[0];
        return SSL_TLSEXT_ERR_OK;
    }

    return SSL_TLSEXT_ERR_NOACK;
}

SSL_CTX *tls_init_server_ctx(const char *certificate_chain_file, const char *private_key_file, bool enable_http2_alpn) {
    SSL_library_init();
    SSL_load_error_strings();
    OpenSSL_add_all_algorithms();

    const SSL_METHOD *tls_method = TLS_server_method();
    SSL_CTX *context = SSL_CTX_new(tls_method);
    if (!context) {
        return NULL;
    }

    SSL_CTX_set_min_proto_version(context, TLS1_2_VERSION);
    SSL_CTX_set_max_proto_version(context, TLS1_3_VERSION);

    SSL_CTX_set_ciphersuites(context, "TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_256_GCM_SHA384");
    SSL_CTX_set_cipher_list(context, "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:"
                                     "ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:HIGH:!aNULL:!MD5");

    SSL_CTX_set_session_cache_mode(context, SSL_SESS_CACHE_OFF);

    long ssl_options = SSL_OP_NO_RENEGOTIATION | SSL_OP_CIPHER_SERVER_PREFERENCE | SSL_OP_NO_TICKET;
#ifdef SSL_OP_NO_COMPRESSION
    ssl_options |= SSL_OP_NO_COMPRESSION;
#endif
#ifdef SSL_OP_DONT_INSERT_EMPTY_FRAGMENTS
    ssl_options |= SSL_OP_DONT_INSERT_EMPTY_FRAGMENTS;
#endif
    SSL_CTX_set_options(context, ssl_options);

    SSL_CTX_set_mode(context,
                     SSL_MODE_ENABLE_PARTIAL_WRITE | SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER | SSL_MODE_RELEASE_BUFFERS);
    SSL_CTX_set_read_ahead(context, 1);

    SSL_CTX_set_alpn_select_cb(context, enable_http2_alpn ? alpn_select_http2_callback : alpn_select_http1_callback,
                               NULL);

    if (SSL_CTX_use_certificate_chain_file(context, certificate_chain_file) <= 0) {
        if (SSL_CTX_use_certificate_file(context, certificate_chain_file, SSL_FILETYPE_PEM) <= 0) {
            SSL_CTX_free(context);
            return NULL;
        }
    }

    if (SSL_CTX_use_PrivateKey_file(context, private_key_file, SSL_FILETYPE_PEM) <= 0) {
        SSL_CTX_free(context);
        return NULL;
    }

    if (!SSL_CTX_check_private_key(context)) {
        SSL_CTX_free(context);
        return NULL;
    }

    return context;
}

void tls_free_server_ctx(SSL_CTX *context) {
    if (context != NULL) {
        SSL_CTX_free(context);
    }
}
