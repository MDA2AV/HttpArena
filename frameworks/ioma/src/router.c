/*
 * router.c - the route table. Exact (method, path) match, linear scan. Registered once before
 * the workers start, then read-only, so it is shared across worker threads without a lock (the
 * shared-nothing rule bends only for immutable data).
 */
#include "http.h"

#include <stdio.h>
#include <string.h>

#ifndef IOMA_MAX_ROUTES
#define IOMA_MAX_ROUTES 256
#endif

typedef struct {
    const char  *method;
    const char  *path;
    ioma_handler fn;
} route_t;

static route_t      g_routes[IOMA_MAX_ROUTES];
static int          g_nroutes;
static ioma_handler g_fallback;

#ifndef IOMA_MAX_MW
#define IOMA_MAX_MW 16
#endif

/* The chain cursor handed to each middleware; ioma_next_run advances it. */
struct ioma_next {
    const ioma_mw *mws;
    int            n;
    int            i;
    ioma_handler   handler;
};

static ioma_mw g_mws[IOMA_MAX_MW];
static int     g_nmw;

void ioma_route(const char *method, const char *path, const ioma_handler fn)
{
    if (g_nroutes == IOMA_MAX_ROUTES) {
        fprintf(stderr, "ioma: route table full (%d), dropping %s %s\n", IOMA_MAX_ROUTES, method, path);
        return;
    }
    g_routes[g_nroutes++] = (route_t){ .method = method, .path = path, .fn = fn };
}

void ioma_default(const ioma_handler fn)
{
    g_fallback = fn;
}

/* Built-in fallback: a plain 404. */
static ioma_response not_found(ioma_request *req)
{
    (void)req;
    return ioma_text(404, "404 Not Found\n");
}

/* Called by the serve loop for each request. Never returns NULL - there is always a handler. */
ioma_handler ioma__match(const ioma_request *req)
{
    for (int i = 0; i < g_nroutes; i++) {
        if (ioma_slice_eq(req->method, req->method_len, g_routes[i].method) &&
            ioma_slice_eq(req->path,   req->path_len,   g_routes[i].path)) {
            return g_routes[i].fn;
        }
    }
    return g_fallback ? g_fallback : not_found;
}

void ioma_use(ioma_mw mw)
{
    if (g_nmw == IOMA_MAX_MW) {
        fprintf(stderr, "ioma: middleware chain full (%d), dropping one\n", IOMA_MAX_MW);
        return;
    }
    g_mws[g_nmw++] = mw;
}

/* Invoke the next middleware in the chain, or the handler once the chain is exhausted. A
 * middleware calls this to pass control on; not calling it short-circuits the request. */
ioma_response ioma_next_run(ioma_request *req, ioma_next *next)
{
    if (next->i < next->n) {
        ioma_mw   mw    = next->mws[next->i];
        ioma_next inner = { next->mws, next->n, next->i + 1, next->handler };
        return mw(req, &inner);
    }
    return next->handler(req);
}

/* Called by the serve loop: run the global middleware chain, then the matched handler. With no
 * middleware registered this is a direct handler call - the chain costs nothing when unused. */
ioma_response ioma__dispatch(ioma_request *req)
{
    ioma_handler h = ioma__match(req);
    if (g_nmw == 0) {
        return h(req);
    }
    ioma_next next = { g_mws, g_nmw, 0, h };
    return ioma_next_run(req, &next);
}
