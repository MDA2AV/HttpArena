#include "h2.h"
#include "dataset.h"
#include "static_files.h"
#include <string.h>

void flush_data(worker_t *w, conn_t *c, const char *data, size_t len);
void close_conn(worker_t *w, conn_t *c);

static ssize_t h2_send_cb(nghttp2_session *session, const uint8_t *data, size_t length, int flags, void *user_data) {
    (void)session; (void)flags;
    h2_conn_t *hc = (h2_conn_t*)user_data;
    worker_t *w = hc->w;
    conn_t *c = hc->c;

    size_t rem = sizeof(w->write_buf) - w->h2_write_pos;
    if (rem < length) {
        if (w->h2_write_pos > 0) {
            flush_data(w, c, w->write_buf, w->h2_write_pos);
            w->h2_write_pos = 0;
            rem = sizeof(w->write_buf);
        }
    }

    if (length <= rem) {
        memcpy(w->write_buf + w->h2_write_pos, data, length);
        w->h2_write_pos += length;
    } else {
        flush_data(w, c, (const char*)data, length);
    }
    return (ssize_t)length;
}

static ssize_t h2_data_read_cb(nghttp2_session *session, int32_t stream_id,
                               uint8_t *buf, size_t length, uint32_t *data_flags,
                               nghttp2_data_source *source, void *user_data) {
    (void)session; (void)user_data;
    h2_conn_t *hc = (h2_conn_t*)source->ptr;
    int slot = (stream_id >> 1) & 127;

    const char *data = NULL;
    size_t len = 0;

    if (hc->stream_dyn_res[slot]) {
        data = hc->stream_dyn_res[slot];
        len = hc->stream_dyn_lens[slot];
    } else {
        data = hc->stream_res[slot];
        len = hc->stream_res_lens[slot];
    }

    if (len > length) len = length;
    if (len > 0 && data) {
        memcpy(buf, data, len);
    }
    *data_flags |= NGHTTP2_DATA_FLAG_EOF;
    return (ssize_t)len;
}

static int h2_on_header_cb(nghttp2_session *session, const nghttp2_frame *frame,
                           const uint8_t *name, size_t namelen,
                           const uint8_t *value, size_t valuelen,
                           uint8_t flags, void *user_data) {
    (void)session; (void)flags;
    h2_conn_t *hc = (h2_conn_t*)user_data;
    if (frame->hd.type == NGHTTP2_HEADERS) {
        int slot = (frame->hd.stream_id >> 1) & 127;
        if (namelen == 5 && memcmp(name, ":path", 5) == 0) {
            size_t l = valuelen < 255 ? valuelen : 255;
            memcpy(hc->stream_paths[slot], value, l);
            hc->stream_paths[slot][l] = '\0';
            hc->stream_path_lens[slot] = l;
        }
    }
    return 0;
}

static int h2_on_stream_close_cb(nghttp2_session *session, int32_t stream_id,
                                 uint32_t error_code, void *user_data) {
    (void)session; (void)error_code;
    h2_conn_t *hc = (h2_conn_t*)user_data;
    int slot = (stream_id >> 1) & 127;
    if (hc->stream_dyn_res[slot]) {
        if (!hc->stream_dyn_is_static[slot]) {
            free(hc->stream_dyn_res[slot]);
        }
        hc->stream_dyn_res[slot] = NULL;
        hc->stream_dyn_lens[slot] = 0;
        hc->stream_dyn_is_static[slot] = false;
    }
    return 0;
}

static int h2_on_frame_recv_cb(nghttp2_session *session, const nghttp2_frame *frame, void *user_data) {
    h2_conn_t *hc = (h2_conn_t*)user_data;
    if (frame->hd.type == NGHTTP2_HEADERS && (frame->hd.flags & NGHTTP2_FLAG_END_STREAM)) {
        int slot = (frame->hd.stream_id >> 1) & 127;
        const char *path = hc->stream_paths[slot];

        // 1. /baseline2 or /baseline11
        if (strncmp(path, "/baseline2", 10) == 0 || strncmp(path, "/baseline11", 11) == 0) {
            int64_t sum = 0;
            const char *q = strchr(path, '?');
            if (q) {
                const char *qp = q + 1;
                while (*qp) {
                    const char *eq = strchr(qp, '=');
                    if (!eq) break;
                    const char *val = eq + 1;
                    const char *amp = strchr(val, '&');
                    int64_t n = 0;
                    int neg = 0;
                    while (*val == ' ' || *val == '\t') val++;
                    if (*val == '-') { neg = 1; val++; }
                    while (*val >= '0' && *val <= '9') {
                        n = n * 10 + (*val - '0');
                        val++;
                    }
                    sum += neg ? -n : n;
                    qp = amp ? amp + 1 : val;
                    if (!amp) break;
                }
            }
            int n = snprintf(hc->stream_res[slot], sizeof(hc->stream_res[slot]), "%lld", (long long)sum);
            hc->stream_res_lens[slot] = (size_t)n;

            nghttp2_nv nva[] = {
                { (uint8_t*)":status", (uint8_t*)"200", 7, 3, NGHTTP2_NV_FLAG_NONE },
                { (uint8_t*)"content-type", (uint8_t*)"text/plain", 12, 10, NGHTTP2_NV_FLAG_NONE }
            };
            nghttp2_data_provider prd = { .source.ptr = hc, .read_callback = h2_data_read_cb };
            nghttp2_submit_response(session, frame->hd.stream_id, nva, 2, &prd);
            return 0;
        }

        // 2. /json/{count}?m=M
        if (strncmp(path, "/json/", 6) == 0) {
            int64_t count = 50;
            const char *pcount = path + 6;
            char *endptr = NULL;
            count = strtoll(pcount, &endptr, 10);
            if (count < 1) count = 1;
            if (count > 50) count = 50;

            int64_t m = 1;
            const char *pm = strstr(path, "m=");
            if (pm) {
                m = strtoll(pm + 2, NULL, 10);
                if (m < 1) m = 1;
            }

            char *jbuf = malloc(16384);
            if (jbuf) {
                size_t jlen = json_serialize((size_t)count, m, jbuf, 16384);
                hc->stream_dyn_res[slot] = jbuf;
                hc->stream_dyn_lens[slot] = jlen;
                hc->stream_dyn_is_static[slot] = false;

                nghttp2_nv nva[] = {
                    { (uint8_t*)":status", (uint8_t*)"200", 7, 3, NGHTTP2_NV_FLAG_NONE },
                    { (uint8_t*)"content-type", (uint8_t*)"application/json", 12, 16, NGHTTP2_NV_FLAG_NONE }
                };
                nghttp2_data_provider prd = { .source.ptr = hc, .read_callback = h2_data_read_cb };
                nghttp2_submit_response(session, frame->hd.stream_id, nva, 2, &prd);
            }
            return 0;
        }

        // 3. /pipeline
        if (strncmp(path, "/pipeline", 9) == 0) {
            memcpy(hc->stream_res[slot], "ok", 2);
            hc->stream_res_lens[slot] = 2;
            nghttp2_nv nva[] = {
                { (uint8_t*)":status", (uint8_t*)"200", 7, 3, NGHTTP2_NV_FLAG_NONE },
                { (uint8_t*)"content-type", (uint8_t*)"text/plain", 12, 10, NGHTTP2_NV_FLAG_NONE }
            };
            nghttp2_data_provider prd = { .source.ptr = hc, .read_callback = h2_data_read_cb };
            nghttp2_submit_response(session, frame->hd.stream_id, nva, 2, &prd);
            return 0;
        }

        // 4. /static/
        if (strncmp(path, "/static/", 8) == 0) {
            const char *rel = path + 8;
            if (!strstr(rel, "..")) {
                const char *sroot = getenv("STATIC_ROOT");
                if (!sroot || !*sroot) sroot = "/data/static";

                char full_path[512];
                snprintf(full_path, sizeof(full_path), "%s/%s", sroot, rel);
                int fd = open(full_path, O_RDONLY);
                if (fd < 0) {
                    snprintf(full_path, sizeof(full_path), "./data/static/%s", rel);
                    fd = open(full_path, O_RDONLY);
                }

                if (fd >= 0) {
                    struct stat st;
                    if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 0 && st.st_size < 10 * 1024 * 1024) {
                        char *buf = malloc((size_t)st.st_size);
                        if (buf) {
                            ssize_t rd = read(fd, buf, (size_t)st.st_size);
                            close(fd);
                            if (rd == st.st_size) {
                                hc->stream_dyn_res[slot] = buf;
                                hc->stream_dyn_lens[slot] = (size_t)rd;
                                hc->stream_dyn_is_static[slot] = false;

                                const char *mime = "application/octet-stream";
                                const char *dot = strrchr(rel, '.');
                                if (dot) {
                                    if (strcmp(dot, ".html") == 0 || strcmp(dot, ".htm") == 0) mime = "text/html; charset=utf-8";
                                    else if (strcmp(dot, ".css") == 0) mime = "text/css";
                                    else if (strcmp(dot, ".js") == 0) mime = "application/javascript";
                                    else if (strcmp(dot, ".json") == 0) mime = "application/json";
                                    else if (strcmp(dot, ".png") == 0) mime = "image/png";
                                    else if (strcmp(dot, ".jpg") == 0 || strcmp(dot, ".jpeg") == 0) mime = "image/jpeg";
                                    else if (strcmp(dot, ".txt") == 0) mime = "text/plain";
                                    else if (strcmp(dot, ".svg") == 0) mime = "image/svg+xml";
                                }

                                nghttp2_nv nva[] = {
                                    { (uint8_t*)":status", (uint8_t*)"200", 7, 3, NGHTTP2_NV_FLAG_NONE },
                                    { (uint8_t*)"content-type", (uint8_t*)mime, 12, strlen(mime), NGHTTP2_NV_FLAG_NONE }
                                };
                                nghttp2_data_provider prd = { .source.ptr = hc, .read_callback = h2_data_read_cb };
                                nghttp2_submit_response(session, frame->hd.stream_id, nva, 2, &prd);
                                return 0;
                            }
                            free(buf);
                        }
                    } else {
                        close(fd);
                    }
                }
            }
        }

        // 5. Fallback 404
        memcpy(hc->stream_res[slot], "Not Found", 9);
        hc->stream_res_lens[slot] = 9;
        nghttp2_nv nva[] = {
            { (uint8_t*)":status", (uint8_t*)"404", 7, 3, NGHTTP2_NV_FLAG_NONE },
            { (uint8_t*)"content-type", (uint8_t*)"text/plain", 12, 10, NGHTTP2_NV_FLAG_NONE }
        };
        nghttp2_data_provider prd = { .source.ptr = hc, .read_callback = h2_data_read_cb };
        nghttp2_submit_response(session, frame->hd.stream_id, nva, 2, &prd);
    }
    return 0;
}

bool h2_conn_init(conn_t *c, worker_t *w) {
    h2_conn_t *hc = calloc(1, sizeof(h2_conn_t));
    if (!hc) return false;
    hc->c = c;
    hc->w = w;
    c->h2 = hc;

    nghttp2_session_callbacks *cbs;
    if (nghttp2_session_callbacks_new(&cbs) != 0) {
        free(hc);
        c->h2 = NULL;
        return false;
    }

    nghttp2_session_callbacks_set_send_callback(cbs, h2_send_cb);
    nghttp2_session_callbacks_set_on_header_callback(cbs, h2_on_header_cb);
    nghttp2_session_callbacks_set_on_frame_recv_callback(cbs, h2_on_frame_recv_cb);
    nghttp2_session_callbacks_set_on_stream_close_callback(cbs, h2_on_stream_close_cb);

    int rc = nghttp2_session_server_new(&hc->session, cbs, hc);
    nghttp2_session_callbacks_del(cbs);
    if (rc != 0) {
        free(hc);
        c->h2 = NULL;
        return false;
    }

    nghttp2_settings_entry iv[] = {
        { NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, 100 },
        { NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, 65535 }
    };
    nghttp2_submit_settings(hc->session, NGHTTP2_FLAG_NONE, iv, 2);

    w->h2_write_pos = 0;
    nghttp2_session_send(hc->session);
    if (w->h2_write_pos > 0) {
        flush_data(w, c, w->write_buf, w->h2_write_pos);
        w->h2_write_pos = 0;
    }

    return true;
}

bool h2_conn_process(conn_t *c, worker_t *w, const char *buf, size_t len) {
    h2_conn_t *hc = (h2_conn_t*)c->h2;
    if (!hc || !hc->session) return false;

    hc->w = w;
    ssize_t proc = nghttp2_session_mem_recv(hc->session, (const uint8_t*)buf, len);
    if (proc < 0) return false;

    w->h2_write_pos = 0;
    int rc = nghttp2_session_send(hc->session);
    if (rc != 0) return false;

    if (w->h2_write_pos > 0) {
        flush_data(w, c, w->write_buf, w->h2_write_pos);
        w->h2_write_pos = 0;
    }

    return true;
}

void h2_conn_free(conn_t *c) {
    if (!c->h2) return;
    h2_conn_t *hc = (h2_conn_t*)c->h2;
    if (hc->session) {
        nghttp2_session_del(hc->session);
        hc->session = NULL;
    }
    for (int i = 0; i < 128; i++) {
        if (hc->stream_dyn_res[i] && !hc->stream_dyn_is_static[i]) {
            free(hc->stream_dyn_res[i]);
            hc->stream_dyn_res[i] = NULL;
        }
    }
    free(hc);
    c->h2 = NULL;
}
