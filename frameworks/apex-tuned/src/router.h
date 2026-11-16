#pragma once

#include "http.h"

typedef struct context_s context_t;

typedef void (*handler_fn_t)(context_t *ctx);
typedef void (*middleware_fn_t)(context_t *ctx, void (*next)(context_t *ctx));

struct context_s {
    request_t *req;
    response_t *res;
    void *user_data;
    bool async_parked;

    const middleware_fn_t *middlewares;
    size_t num_middlewares;
    size_t mw_index;
    handler_fn_t handler;
};

typedef struct {
    http_method_t method;
    char pattern[64];
    size_t pattern_len;
    size_t prefix_len;
    handler_fn_t handler;
    bool is_prefix;
    bool has_param;
} route_entry_t;

typedef struct {
    route_entry_t routes[64];
    size_t num_routes;
    middleware_fn_t middlewares[16];
    size_t num_middlewares;
} router_t;

void router_init(router_t *r);
void router_use(router_t *r, middleware_fn_t mw);
void router_add(router_t *r, http_method_t method, const char *pattern, handler_fn_t handler);

void ctx_next(context_t *ctx);
bool router_dispatch(const router_t *r, request_t *req, response_t *res, void *user_data, bool *async_parked_out);
