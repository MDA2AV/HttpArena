#include "tls.h"

static int alpn_select_cb(SSL *ssl, const unsigned char **out, unsigned char *outlen,
                          const unsigned char *in, unsigned int inlen, void *arg) {
    (void)ssl; (void)arg;
    for (unsigned int i = 0; i < inlen; ) {
        unsigned char proto_len = in[i++];
        if (i + proto_len > inlen) break;
        if (proto_len == 8 && memcmp(&in[i], "http/1.1", 8) == 0) {
            *out = &in[i];
            *outlen = proto_len;
            return SSL_TLSEXT_ERR_OK;
        }
        i += proto_len;
    }
    if (inlen > 0) {
        *out = &in[1];
        *outlen = in[0];
        return SSL_TLSEXT_ERR_OK;
    }
    return SSL_TLSEXT_ERR_NOACK;
}

SSL_CTX* tls_init_server_ctx(const char *cert_file, const char *key_file) {
    SSL_library_init();
    SSL_load_error_strings();
    OpenSSL_add_all_algorithms();

    const SSL_METHOD *method = TLS_server_method();
    SSL_CTX *ctx = SSL_CTX_new(method);
    if (!ctx) return NULL;

    SSL_CTX_set_min_proto_version(ctx, TLS1_3_VERSION);
    SSL_CTX_set_max_proto_version(ctx, TLS1_3_VERSION);
    SSL_CTX_set_ciphersuites(ctx, "TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_256_GCM_SHA384");
    SSL_CTX_set_session_cache_mode(ctx, SSL_SESS_CACHE_OFF);

    long options = SSL_OP_NO_RENEGOTIATION | SSL_OP_CIPHER_SERVER_PREFERENCE | SSL_OP_NO_TICKET;
#ifdef SSL_OP_ENABLE_KTLS
    options |= SSL_OP_ENABLE_KTLS;
#endif
#ifdef SSL_OP_NO_COMPRESSION
    options |= SSL_OP_NO_COMPRESSION;
#endif
#ifdef SSL_OP_DONT_INSERT_EMPTY_FRAGMENTS
    options |= SSL_OP_DONT_INSERT_EMPTY_FRAGMENTS;
#endif
    SSL_CTX_set_options(ctx, options);
    SSL_CTX_set_mode(ctx, SSL_MODE_ENABLE_PARTIAL_WRITE | SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER | SSL_MODE_RELEASE_BUFFERS);
    SSL_CTX_set_read_ahead(ctx, 1);
    SSL_CTX_set_alpn_select_cb(ctx, alpn_select_cb, NULL);

    if (SSL_CTX_use_certificate_file(ctx, cert_file, SSL_FILETYPE_PEM) <= 0) {
        SSL_CTX_free(ctx);
        return NULL;
    }
    if (SSL_CTX_use_PrivateKey_file(ctx, key_file, SSL_FILETYPE_PEM) <= 0) {
        SSL_CTX_free(ctx);
        return NULL;
    }
    if (!SSL_CTX_check_private_key(ctx)) {
        SSL_CTX_free(ctx);
        return NULL;
    }

    return ctx;
}

void tls_free_server_ctx(SSL_CTX *ctx) {
    if (ctx) {
        SSL_CTX_free(ctx);
    }
}
