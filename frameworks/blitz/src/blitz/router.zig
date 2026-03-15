const std = @import("std");
const mem = std.mem;
const types = @import("types.zig");
const static_mod = @import("static.zig");
const Method = types.Method;
const Request = types.Request;
const Response = types.Response;
const HandlerFn = types.HandlerFn;
const MiddlewareFn = types.MiddlewareFn;
const StaticDirConfig = static_mod.StaticDirConfig;

// ── Radix-trie Router ──────────────────────────────────────────────
// Fast path matching with support for:
//   - Static paths: /users, /api/v1/health
//   - Path parameters: /users/:id, /posts/:id/comments
//   - Wildcard: /static/*filepath
//   - Middleware: global and per-route middleware chains

const MAX_CHILDREN = 64;
const MAX_METHODS = 7; // GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS
const MAX_MIDDLEWARE = 16;
const MAX_ROUTE_MW = 8; // Max middleware per node (route/group level)
const MAX_PATH_MW = 32; // Max middleware collected along a matched path

const Node = struct {
    // Path segment for this node
    segment: []const u8 = "",
    // Handlers indexed by method
    handlers: [MAX_METHODS]?HandlerFn = .{null} ** MAX_METHODS,
    // Children
    children: [MAX_CHILDREN]*Node = undefined,
    children_count: usize = 0,
    // Parameter child (e.g. :id)
    param_child: ?*Node = null,
    param_name: []const u8 = "",
    // Wildcard child (e.g. *filepath)
    wildcard_child: ?*Node = null,
    wildcard_name: []const u8 = "",
    // Per-node middleware (inherited by child routes)
    node_middleware: [MAX_ROUTE_MW]MiddlewareFn = undefined,
    node_middleware_count: usize = 0,

    fn methodIndex(m: Method) usize {
        return @intFromEnum(m);
    }

    fn findChild(self: *Node, segment: []const u8) ?*Node {
        for (self.children[0..self.children_count]) |child| {
            if (mem.eql(u8, child.segment, segment)) return child;
        }
        return null;
    }

    fn addMiddleware(self: *Node, mw: MiddlewareFn) void {
        if (self.node_middleware_count < MAX_ROUTE_MW) {
            self.node_middleware[self.node_middleware_count] = mw;
            self.node_middleware_count += 1;
        }
    }
};

pub const Router = struct {
    root: *Node,
    alloc: std.mem.Allocator,
    not_found_handler: ?HandlerFn = null,
    // Global middleware chain
    middleware: [MAX_MIDDLEWARE]MiddlewareFn = undefined,
    middleware_count: usize = 0,
    // Static directory mappings
    static_dirs: [static_mod.MAX_STATIC_DIRS]StaticDirConfig = undefined,
    static_dir_count: usize = 0,

    pub fn init(alloc: std.mem.Allocator) Router {
        const root = alloc.create(Node) catch @panic("OOM");
        root.* = .{};
        return .{ .root = root, .alloc = alloc };
    }

    /// Serve static files from a directory.
    /// Example: router.staticDir("/static", "./public", .{});
    pub fn staticDir(self: *Router, prefix: []const u8, root_dir: []const u8, opts: struct {
        index: bool = true,
        max_file_size: usize = 50 * 1024 * 1024,
        cache_control: []const u8 = "",
    }) void {
        if (self.static_dir_count >= static_mod.MAX_STATIC_DIRS) return;
        self.static_dirs[self.static_dir_count] = .{
            .prefix = prefix,
            .root = root_dir,
            .index = opts.index,
            .max_file_size = opts.max_file_size,
            .cache_control = opts.cache_control,
        };
        self.static_dir_count += 1;
    }

    /// Add global middleware (runs on every request before the handler).
    /// Returns true to continue, false to short-circuit.
    pub fn use(self: *Router, mw: MiddlewareFn) void {
        if (self.middleware_count < MAX_MIDDLEWARE) {
            self.middleware[self.middleware_count] = mw;
            self.middleware_count += 1;
        }
    }

    /// Add middleware to a specific path prefix.
    /// All routes under this prefix will run this middleware (after global middleware).
    /// Example: router.useAt("/api", authMiddleware);
    pub fn useAt(self: *Router, pattern: []const u8, mw: MiddlewareFn) void {
        const node = self.ensureNode(pattern);
        node.addMiddleware(mw);
    }

    /// Navigate to (or create) the node for a given path pattern.
    /// Used internally for attaching per-route middleware.
    fn ensureNode(self: *Router, pattern: []const u8) *Node {
        var node = self.root;
        var path = pattern;
        if (path.len > 0 and path[0] == '/') path = path[1..];
        if (path.len == 0) return node;

        var it = mem.splitScalar(u8, path, '/');
        while (it.next()) |segment| {
            if (segment.len == 0) continue;

            if (segment[0] == ':') {
                if (node.param_child == null) {
                    const child = self.alloc.create(Node) catch @panic("OOM");
                    child.* = .{};
                    node.param_child = child;
                    node.param_name = segment[1..];
                }
                node = node.param_child.?;
            } else if (segment[0] == '*') {
                if (node.wildcard_child == null) {
                    const child = self.alloc.create(Node) catch @panic("OOM");
                    child.* = .{};
                    node.wildcard_child = child;
                    node.wildcard_name = segment[1..];
                }
                node = node.wildcard_child.?;
                break;
            } else {
                if (node.findChild(segment)) |child| {
                    node = child;
                } else {
                    const child = self.alloc.create(Node) catch @panic("OOM");
                    child.* = .{ .segment = segment };
                    if (node.children_count < MAX_CHILDREN) {
                        node.children[node.children_count] = child;
                        node.children_count += 1;
                    }
                    node = child;
                }
            }
        }
        return node;
    }

    /// Register a handler for a method + path pattern
    pub fn route(self: *Router, method: Method, pattern: []const u8, handler: HandlerFn) void {
        var node = self.root;
        var path = pattern;

        // Strip leading slash
        if (path.len > 0 and path[0] == '/') path = path[1..];

        // Empty path = root
        if (path.len == 0) {
            node.handlers[Node.methodIndex(method)] = handler;
            return;
        }

        var it = mem.splitScalar(u8, path, '/');
        while (it.next()) |segment| {
            if (segment.len == 0) continue;

            if (segment[0] == ':') {
                // Parameter segment
                if (node.param_child == null) {
                    const child = self.alloc.create(Node) catch @panic("OOM");
                    child.* = .{};
                    node.param_child = child;
                    node.param_name = segment[1..];
                }
                node = node.param_child.?;
            } else if (segment[0] == '*') {
                // Wildcard segment (must be last)
                if (node.wildcard_child == null) {
                    const child = self.alloc.create(Node) catch @panic("OOM");
                    child.* = .{};
                    node.wildcard_child = child;
                    node.wildcard_name = segment[1..];
                }
                node = node.wildcard_child.?;
                break;
            } else {
                // Static segment
                if (node.findChild(segment)) |child| {
                    node = child;
                } else {
                    const child = self.alloc.create(Node) catch @panic("OOM");
                    child.* = .{ .segment = segment };
                    if (node.children_count < MAX_CHILDREN) {
                        node.children[node.children_count] = child;
                        node.children_count += 1;
                    }
                    node = child;
                }
            }
        }

        node.handlers[Node.methodIndex(method)] = handler;
    }

    /// Convenience methods
    pub fn get(self: *Router, pattern: []const u8, handler: HandlerFn) void {
        self.route(.GET, pattern, handler);
    }

    pub fn post(self: *Router, pattern: []const u8, handler: HandlerFn) void {
        self.route(.POST, pattern, handler);
    }

    pub fn put(self: *Router, pattern: []const u8, handler: HandlerFn) void {
        self.route(.PUT, pattern, handler);
    }

    pub fn delete(self: *Router, pattern: []const u8, handler: HandlerFn) void {
        self.route(.DELETE, pattern, handler);
    }

    pub fn patch(self: *Router, pattern: []const u8, handler: HandlerFn) void {
        self.route(.PATCH, pattern, handler);
    }

    pub fn head(self: *Router, pattern: []const u8, handler: HandlerFn) void {
        self.route(.HEAD, pattern, handler);
    }

    pub fn options(self: *Router, pattern: []const u8, handler: HandlerFn) void {
        self.route(.OPTIONS, pattern, handler);
    }

    /// Create a route group with a shared prefix.
    /// Returns a Group that registers routes under the prefix.
    pub fn group(self: *Router, prefix: []const u8) Group {
        return .{ .router = self, .prefix = prefix };
    }

    /// Collected route middleware from a matched path
    pub const RouteMiddleware = struct {
        items: [MAX_PATH_MW]MiddlewareFn = undefined,
        len: usize = 0,

        pub fn append(self: *RouteMiddleware, mw_list: []const MiddlewareFn) void {
            for (mw_list) |mw| {
                if (self.len < MAX_PATH_MW) {
                    self.items[self.len] = mw;
                    self.len += 1;
                }
            }
        }
    };

    /// Match a request path and return the handler + fill params
    pub fn match(self: *Router, method: Method, path: []const u8, params: *Request.Params) ?HandlerFn {
        var route_mw = RouteMiddleware{};
        return self.matchWithMiddleware(method, path, params, &route_mw);
    }

    /// Match a request path and return the handler + fill params + collect per-route middleware
    pub fn matchWithMiddleware(self: *Router, method: Method, path: []const u8, params: *Request.Params, route_mw: *RouteMiddleware) ?HandlerFn {
        var p = path;
        if (p.len > 0 and p[0] == '/') p = p[1..];

        // Collect root node middleware
        if (self.root.node_middleware_count > 0) {
            route_mw.append(self.root.node_middleware[0..self.root.node_middleware_count]);
        }

        // Root path
        if (p.len == 0) {
            return self.root.handlers[Node.methodIndex(method)];
        }

        return matchNode(self.root, method, p, params, route_mw);
    }

    fn matchNode(node: *Node, method: Method, remaining: []const u8, params: *Request.Params, route_mw: *RouteMiddleware) ?HandlerFn {
        if (remaining.len == 0) {
            return node.handlers[Node.methodIndex(method)];
        }

        // Find next segment
        const slash_pos = mem.indexOfScalar(u8, remaining, '/');
        const segment = if (slash_pos) |sp| remaining[0..sp] else remaining;
        const rest = if (slash_pos) |sp| remaining[sp + 1 ..] else "";

        // 1. Try static children first (most specific)
        for (node.children[0..node.children_count]) |child| {
            if (mem.eql(u8, child.segment, segment)) {
                const mw_before = route_mw.len;
                if (child.node_middleware_count > 0) {
                    route_mw.append(child.node_middleware[0..child.node_middleware_count]);
                }
                if (matchNode(child, method, rest, params, route_mw)) |h| return h;
                // Rollback middleware on backtrack
                route_mw.len = mw_before;
            }
        }

        // 2. Try parameter child
        if (node.param_child) |pchild| {
            const mw_before = route_mw.len;
            if (pchild.node_middleware_count > 0) {
                route_mw.append(pchild.node_middleware[0..pchild.node_middleware_count]);
            }
            params.set(node.param_name, segment);
            if (matchNode(pchild, method, rest, params, route_mw)) |h| return h;
            // Rollback param and middleware on backtrack
            if (params.len > 0) params.len -= 1;
            route_mw.len = mw_before;
        }

        // 3. Try wildcard child
        if (node.wildcard_child) |_| {
            params.set(node.wildcard_name, remaining);
            const wnode = node.wildcard_child.?;
            if (wnode.node_middleware_count > 0) {
                route_mw.append(wnode.node_middleware[0..wnode.node_middleware_count]);
            }
            return wnode.handlers[Node.methodIndex(method)];
        }

        return null;
    }

    /// Handle a request — runs global middleware, per-route middleware, then handler
    pub fn handle(self: *Router, req: *Request, res: *Response) void {
        // Run global middleware chain
        for (self.middleware[0..self.middleware_count]) |mw| {
            if (!mw(req, res)) return; // Middleware short-circuited
        }

        var params = Request.Params{};
        var route_mw = RouteMiddleware{};
        if (self.matchWithMiddleware(req.method, req.path, &params, &route_mw)) |handler| {
            req.params = params;
            // Run per-route middleware collected along the matched path
            for (route_mw.items[0..route_mw.len]) |mw| {
                if (!mw(req, res)) return;
            }
            handler(req, res);
        } else if (self.tryStaticFile(req, res)) {
            // Static file served successfully
        } else if (self.not_found_handler) |nf| {
            nf(req, res);
        } else {
            _ = res.setStatus(.not_found).text("Not Found");
        }
    }

    /// Try to serve a static file from configured static directories.
    /// Only serves GET and HEAD requests.
    fn tryStaticFile(self: *Router, req: *Request, res: *Response) bool {
        // Only serve static files for GET and HEAD
        if (req.method != .GET and req.method != .HEAD) return false;

        for (self.static_dirs[0..self.static_dir_count]) |dir_config| {
            const prefix = mem.trimRight(u8, dir_config.prefix, "/");

            // Check if the request path starts with the prefix
            if (!mem.startsWith(u8, req.path, prefix)) continue;

            // Extract the filepath after the prefix
            const remaining = req.path[prefix.len..];

            // Must be exactly the prefix or followed by /
            if (remaining.len == 0) {
                // Exact prefix match — try index
                if (dir_config.index) {
                    if (static_mod.serveFile(res, dir_config.root, "index.html", dir_config)) {
                        return true;
                    }
                }
                continue;
            }

            if (remaining[0] != '/') continue;

            // Strip leading slash to get relative filepath
            const filepath = remaining[1..];
            if (filepath.len == 0) {
                if (dir_config.index) {
                    if (static_mod.serveFile(res, dir_config.root, "index.html", dir_config)) {
                        return true;
                    }
                }
                continue;
            }

            if (static_mod.serveFile(res, dir_config.root, filepath, dir_config)) {
                return true;
            }
        }

        return false;
    }

    /// Set a custom 404 handler
    pub fn notFound(self: *Router, handler: HandlerFn) void {
        self.not_found_handler = handler;
    }
};

// ── Route Group ─────────────────────────────────────────────────────
// Groups register routes under a shared prefix.
// Usage: var api = router.group("/api/v1");
//        api.get("/users", listUsers);   // matches /api/v1/users
//        api.post("/users", createUser);

pub const Group = struct {
    router: *Router,
    prefix: []const u8,

    fn buildPath(self: Group, pattern: []const u8) ?[]const u8 {
        const prefix = mem.trimRight(u8, self.prefix, "/");
        const pat = pattern;
        const len = prefix.len + pat.len;
        const full = self.router.alloc.alloc(u8, len) catch return null;
        @memcpy(full[0..prefix.len], prefix);
        @memcpy(full[prefix.len..len], pat);
        return full;
    }

    pub fn route(self: Group, method: Method, pattern: []const u8, handler: HandlerFn) void {
        const full = self.buildPath(pattern) orelse return;
        self.router.route(method, full, handler);
    }

    /// Add middleware to this group's prefix.
    /// All routes registered under this group will inherit this middleware.
    pub fn use(self: Group, mw: MiddlewareFn) void {
        self.router.useAt(self.prefix, mw);
    }

    pub fn get(self: Group, pattern: []const u8, handler: HandlerFn) void {
        self.route(.GET, pattern, handler);
    }

    pub fn post(self: Group, pattern: []const u8, handler: HandlerFn) void {
        self.route(.POST, pattern, handler);
    }

    pub fn put(self: Group, pattern: []const u8, handler: HandlerFn) void {
        self.route(.PUT, pattern, handler);
    }

    pub fn delete(self: Group, pattern: []const u8, handler: HandlerFn) void {
        self.route(.DELETE, pattern, handler);
    }

    pub fn patch(self: Group, pattern: []const u8, handler: HandlerFn) void {
        self.route(.PATCH, pattern, handler);
    }

    /// Nest a sub-group under this group's prefix
    pub fn group(self: Group, prefix: []const u8) Group {
        const full = self.buildPath(prefix) orelse return .{ .router = self.router, .prefix = self.prefix };
        return .{ .router = self.router, .prefix = full };
    }
};
