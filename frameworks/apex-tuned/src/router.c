#include "router.h"

void router_init(router_t *r) {
    memset(r, 0, sizeof(*r));
}

void router_use(router_t *r, middleware_fn_t mw) {
    if (r->num_middlewares < 16) {
        r->middlewares[r->num_middlewares++] = mw;
    }
}

void router_add(router_t *r, http_method_t method, const char *pattern, handler_fn_t handler) {
    if (r->num_routes >= 64) return;
    route_entry_t *re = &r->routes[r->num_routes++];
    re->method = method;
    strncpy(re->pattern, pattern, sizeof(re->pattern) - 1);
    re->handler = handler;
    re->has_param = (strstr(pattern, "/:") != NULL);
    re->is_prefix = (strlen(pattern) > 0 && pattern[strlen(pattern) - 1] == '/');
}

void ctx_next(context_t *ctx) {
    if (ctx->mw_index < ctx->num_middlewares) {
        middleware_fn_t mw = ctx->middlewares[ctx->mw_index++];
        mw(ctx, ctx_next);
    } else if (ctx->handler) {
        ctx->handler(ctx);
    }
}

static bool match_route(const route_entry_t *re, request_t *req) {
    if (re->method != req->method) return false;

    if (re->has_param) {
        const char *param_marker = strstr(re->pattern, "/:");
        size_t prefix_len = param_marker - re->pattern + 1;
        if (req->path.len < prefix_len) return false;
        if (memcmp(req->path.ptr, re->pattern, prefix_len) != 0) return false;

        const char *param_start = req->path.ptr + prefix_len;
        const char *path_end = req->path.ptr + req->path.len;
        const char *slash = memchr(param_start, '/', path_end - param_start);
        size_t param_len = slash ? (size_t)(slash - param_start) : (size_t)(path_end - param_start);

        req->route_params[0] = (str_view_t){ param_start, param_len };
        req->num_route_params = 1;
        return true;
    }

    if (re->is_prefix) {
        size_t plen = strlen(re->pattern);
        if (req->path.len < plen) return false;
        if (memcmp(req->path.ptr, re->pattern, plen) != 0) return false;

        req->route_params[0] = (str_view_t){ req->path.ptr + plen, req->path.len - plen };
        req->num_route_params = 1;
        return true;
    }

    return view_eq(req->path, re->pattern);
}

bool router_dispatch(const router_t *r, request_t *req, response_t *res, void *user_data, bool *async_parked_out) {
    req_parse_query(req);

    for (size_t i = 0; i < r->num_routes; i++) {
        if (match_route(&r->routes[i], req)) {
            context_t ctx = {
                .req = req,
                .res = res,
                .user_data = user_data,
                .async_parked = false,
                .middlewares = (middleware_fn_t*)r->middlewares,
                .num_middlewares = r->num_middlewares,
                .mw_index = 0,
                .handler = r->routes[i].handler
            };

            ctx_next(&ctx);
            if (async_parked_out) {
                *async_parked_out = ctx.async_parked;
            }
            return true;
        }
    }

    return false;
}
