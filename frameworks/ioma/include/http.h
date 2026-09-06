/*
 * http.h - the ioma HTTP/1.1 layer: what you write endpoints against.
 *
 * An endpoint takes a parsed request and returns a response by value; the framework serializes it
 * and flushes it to the wire on the connection's coroutine (the flush suspends until the send
 * completes). Requests and their slices are zero-copy views into the read buffer, valid only for
 * the duration of the handler call.
 *
 *     static ioma_response home(ioma_request *req) { return ioma_text(200, "hi\n"); }
 *     int main(void) {
 *         ioma_route("GET", "/", home);
 *         return ioma_run(4, 8080);          // 4 workers, one per core
 *     }
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>

typedef struct conn conn_t;                 /* opaque here; only advanced handlers touch it */

#ifndef IOMA_MAX_HEADERS
#define IOMA_MAX_HEADERS      64            /* request headers parsed                        */
#endif
#ifndef IOMA_MAX_RESP_HEADERS
#define IOMA_MAX_RESP_HEADERS 16            /* extra headers a handler may add               */
#endif

/* One header, as name/value slices. On a request these point into the read buffer; on a response
 * they point at whatever the handler passed (a literal, or its request scratch). */
typedef struct {
    const char *name;  size_t name_len;
    const char *value; size_t value_len;
} ioma_header;

/* A parsed request. Every pointer is a view into the connection's read buffer and is valid only
 * until the handler returns - copy anything you need to keep. */
typedef struct ioma_request {
    const char *method; size_t method_len;      /* "GET", "POST", ...                        */
    const char *target; size_t target_len;      /* raw request target: path plus any query   */
    const char *path;   size_t path_len;        /* the path, query stripped                  */
    const char *query;  size_t query_len;       /* after '?', or NULL/0 if none              */
    int         minor_version;                  /* 0 or 1 for HTTP/1.0 or 1.1                */

    ioma_header headers[IOMA_MAX_HEADERS];
    size_t      n_headers;

    const char *body;   size_t body_len;        /* Content-Length body (may be empty)        */
    bool        keep_alive;                     /* computed from version + Connection         */

    conn_t     *conn;                           /* advanced: await_recv/await_send in a handler */
    char       *scratch; size_t scratch_cap;    /* per-request arena for building a body      */
} ioma_request;

/* A response the handler builds and returns. body points at memory that stays valid until the
 * send completes: a string literal, static data, or the request scratch (see ioma_textf). */
typedef struct ioma_response {
    int          status;                        /* 200, 404, ...                             */
    const char  *content_type;                  /* NULL -> "text/plain"                      */
    const void  *body; size_t body_len;
    ioma_header  extra[IOMA_MAX_RESP_HEADERS];  /* headers added with ioma_header_set        */
    int          n_extra;
    bool         close;                         /* force Connection: close after this reply  */
} ioma_response;

typedef ioma_response (*ioma_handler)(ioma_request *req);

/* Middleware runs around the handler (the onion model): do work before, call ioma_next_run to
 * invoke the rest of the chain and then the endpoint, then do work after and return its response -
 * or return a response WITHOUT calling ioma_next_run to short-circuit (auth failure, cache hit). */
typedef struct ioma_next ioma_next;
typedef ioma_response (*ioma_mw)(ioma_request *req, ioma_next *next);
ioma_response ioma_next_run(ioma_request *req, ioma_next *next);

/* ── response builders ─────────────────────────────────────────────────────────────────── */

ioma_response ioma_text (int status, const char *s);                      /* text/plain, strlen(s)   */
ioma_response ioma_json (int status, const char *s);                      /* application/json         */
ioma_response ioma_bytes(int status, const char *content_type,
                         const void *body, size_t body_len);
/* printf a body into req->scratch (truncated to scratch_cap) and return it as text/plain */
ioma_response ioma_textf(ioma_request *req, int status, const char *fmt, ...)
    __attribute__((format(printf, 3, 4)));
/* Add a response header. name/value must stay valid until the reply is sent. */
void ioma_header_set(ioma_response *res, const char *name, const char *value);

/* ── request helpers ───────────────────────────────────────────────────────────────────── */

/* Case-insensitive header lookup. Returns the value slice (not NUL-terminated) or NULL. */
const char *ioma_header_get(const ioma_request *req, const char *name, size_t *value_len);
/* strcmp-style compare of a slice against a C string (path/method matching). */
bool ioma_slice_eq(const char *s, size_t n, const char *cstr);

/* ── routing ───────────────────────────────────────────────────────────────────────────── */

/* Register an endpoint. method and path are matched exactly (path, query ignored). Call these
 * before ioma_run, from the main thread; the table is then read-only and shared by all workers. */
void ioma_route(const char *method, const char *path, ioma_handler fn);
/* Fallback handler when nothing matches (default is a built-in 404). */
void ioma_default(ioma_handler fn);

/* Register global middleware; it runs on every request in the order added, wrapping the handler. */
void ioma_use(ioma_mw mw);

/* ── run ───────────────────────────────────────────────────────────────────────────────── */

/* Start `workers` proactor threads (one per core) serving HTTP on `port`, and block until
 * SIGINT/SIGTERM. Returns 0 on clean shutdown. */
int ioma_run(int workers, int port);

/* The reason phrase for a status code ("OK", "Not Found", ...); "Unknown" if unlisted. */
const char *ioma_reason(int status);
