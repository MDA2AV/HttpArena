#pragma once

#include "server.h"
#include <nghttp2/nghttp2.h>

typedef struct h2_conn_s {
    conn_t *c;
    worker_t *w;
    nghttp2_session *session;
    char stream_paths[128][256];
    size_t stream_path_lens[128];
    char stream_res[128][32];
    size_t stream_res_lens[128];
    char *stream_dyn_res[128];
    size_t stream_dyn_lens[128];
    bool stream_dyn_is_static[128];
} h2_conn_t;

bool h2_conn_init(conn_t *c, worker_t *w);
bool h2_conn_process(conn_t *c, worker_t *w, const char *buf, size_t len);
void h2_conn_free(conn_t *c);
