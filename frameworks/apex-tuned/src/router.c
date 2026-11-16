#include "router.h"

void router_init(router_t *router) {
    memset(router, 0, sizeof(*router));
}

void router_use(router_t *router, middleware_fn_t middleware) {
    if (router->num_middlewares < 16) {
        router->middlewares[router->num_middlewares++] = middleware;
    }
}

void router_add(router_t *router, http_method_t method, const char *pattern, handler_fn_t handler) {
    if (router->num_routes >= 64) {
        return;
    }
    route_entry_t *entry = &router->routes[router->num_routes++];
    entry->method = method;
    strncpy(entry->pattern, pattern, sizeof(entry->pattern) - 1);
    entry->pattern_len = strlen(entry->pattern);
    entry->handler = handler;

    const char *param_marker = strstr(pattern, "/:");
    if (param_marker) {
        entry->has_param = true;
        entry->is_prefix = false;
        entry->prefix_len = (size_t)(param_marker - pattern + 1);
    } else {
        entry->has_param = false;
        entry->is_prefix = (entry->pattern_len > 1 && pattern[entry->pattern_len - 1] == '/');
        entry->prefix_len = entry->pattern_len;
    }
}

void ctx_next(context_t *context) {
    if (context->mw_index < context->num_middlewares) {
        middleware_fn_t middleware = context->middlewares[context->mw_index++];
        middleware(context, ctx_next);
    } else if (context->handler) {
        context->handler(context);
    }
}

static inline bool match_route(const route_entry_t *route, request_t *request) {
    if (route->method != request->method) {
        return false;
    }

    if (route->has_param) {
        if (request->path.len < route->prefix_len) {
            return false;
        }
        if (memcmp(request->path.ptr, route->pattern, route->prefix_len) != 0) {
            return false;
        }

        const char *param_start = request->path.ptr + route->prefix_len;
        const char *path_end = request->path.ptr + request->path.len;
        const char *slash = memchr(param_start, '/', (size_t)(path_end - param_start));
        size_t param_length = slash ? (size_t)(slash - param_start) : (size_t)(path_end - param_start);

        request->route_params[0] = (str_view_t){param_start, param_length};
        request->num_route_params = 1;
        return true;
    }

    if (route->is_prefix) {
        if (request->path.len < route->prefix_len) {
            return false;
        }
        if (memcmp(request->path.ptr, route->pattern, route->prefix_len) != 0) {
            return false;
        }

        request->route_params[0] =
            (str_view_t){request->path.ptr + route->prefix_len, request->path.len - route->prefix_len};
        request->num_route_params = 1;
        return true;
    }

    return (request->path.len == route->pattern_len &&
            memcmp(request->path.ptr, route->pattern, route->pattern_len) == 0);
}

bool router_dispatch(const router_t *router, request_t *request, response_t *response, void *user_data,
                     bool *out_is_async_parked) {
    if (request->query.len > 0) {
        req_parse_query(request);
    }

    for (size_t route_index = 0; route_index < router->num_routes; route_index++) {
        if (match_route(&router->routes[route_index], request)) {
            context_t context = {.req = request,
                                 .res = response,
                                 .user_data = user_data,
                                 .async_parked = false,
                                  .middlewares = router->middlewares,
                                 .num_middlewares = router->num_middlewares,
                                 .mw_index = 0,
                                 .handler = router->routes[route_index].handler};

            ctx_next(&context);
            if (out_is_async_parked) {
                *out_is_async_parked = context.async_parked;
            }
            return true;
        }
    }

    return false;
}
