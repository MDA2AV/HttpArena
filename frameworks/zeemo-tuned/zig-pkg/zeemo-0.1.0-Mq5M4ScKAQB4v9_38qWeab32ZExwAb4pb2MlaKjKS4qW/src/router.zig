//! Runtime route registration with `:param` segment capture and an optional
//! "static prefix" for serving files. Linear scan over routes — fast enough
//! for the typical ~10 endpoints in a benchmark or small service; if a user
//! ever needs hundreds of routes a trie can be slotted in here without
//! changing the public API.

const std = @import("std");
const http = @import("http.zig");

pub const HandlerFn = *const fn (req: *const @import("request.zig").Request, res: *@import("response.zig").Response) anyerror!void;

pub const Params = struct {
    pub const Capacity = 4;
    items: [Capacity]Pair = undefined,
    len: u8 = 0,

    const Pair = struct { name: []const u8, value: []const u8 };

    pub fn get(self: *const Params, name: []const u8) ?[]const u8 {
        var i: u8 = 0;
        while (i < self.len) : (i += 1) {
            if (std.mem.eql(u8, self.items[i].name, name)) return self.items[i].value;
        }
        return null;
    }
};

const Segment = union(enum) {
    literal: []const u8,
    param: []const u8,
};

const Route = struct {
    method: http.Method,
    segments: []Segment,
    handler: HandlerFn,
};

const StaticMount = struct {
    url_prefix: []const u8,
    fs_root: []const u8,
    handler: HandlerFn,
};

pub const Router = struct {
    allocator: std.mem.Allocator,
    routes: std.ArrayList(Route) = .empty,
    mounts: std.ArrayList(StaticMount) = .empty,

    pub fn init(allocator: std.mem.Allocator) Router {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Router) void {
        for (self.routes.items) |r| self.allocator.free(r.segments);
        self.routes.deinit(self.allocator);
        self.mounts.deinit(self.allocator);
    }

    pub fn add(self: *Router, method: http.Method, pattern: []const u8, handler: HandlerFn) !void {
        const segs = try parsePattern(self.allocator, pattern);
        try self.routes.append(self.allocator, .{ .method = method, .segments = segs, .handler = handler });
    }

    pub fn get(self: *Router, pattern: []const u8, handler: HandlerFn) !void {
        try self.add(.GET, pattern, handler);
    }

    pub fn post(self: *Router, pattern: []const u8, handler: HandlerFn) !void {
        try self.add(.POST, pattern, handler);
    }

    /// Register a static-file mount: requests to `url_prefix` are served from
    /// files under `fs_root`. The handler is supplied by the caller — usually
    /// a stock implementation from `zeemo.static`.
    pub fn staticMount(self: *Router, url_prefix: []const u8, fs_root: []const u8, handler: HandlerFn) !void {
        try self.mounts.append(self.allocator, .{
            .url_prefix = url_prefix,
            .fs_root = fs_root,
            .handler = handler,
        });
    }

    pub const Match = struct {
        handler: HandlerFn,
        params: Params,
        /// Filesystem root for static mounts; empty for normal routes.
        static_root: []const u8 = "",
    };

    pub fn match(self: *const Router, method: http.Method, path: []const u8) ?Match {
        for (self.routes.items) |r| {
            if (r.method != method and method != .OTHER) continue;
            if (matchSegments(r.segments, path)) |params| {
                return .{ .handler = r.handler, .params = params };
            }
        }
        // Static mounts only respond to GET.
        if (method == .GET) {
            for (self.mounts.items) |m| {
                if (std.mem.startsWith(u8, path, m.url_prefix)) {
                    return .{ .handler = m.handler, .params = .{}, .static_root = m.fs_root };
                }
            }
        }
        return null;
    }
};

fn parsePattern(allocator: std.mem.Allocator, pattern: []const u8) ![]Segment {
    var segs: std.ArrayList(Segment) = .empty;
    errdefer segs.deinit(allocator);
    var it = std.mem.splitScalar(u8, pattern, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (seg[0] == ':') {
            try segs.append(allocator, .{ .param = seg[1..] });
        } else {
            try segs.append(allocator, .{ .literal = seg });
        }
    }
    return segs.toOwnedSlice(allocator);
}

fn matchSegments(pattern: []const Segment, path: []const u8) ?Params {
    var params: Params = .{};
    var path_it = std.mem.splitScalar(u8, path, '/');
    var i: usize = 0;
    while (path_it.next()) |seg| {
        if (seg.len == 0) continue;
        if (i >= pattern.len) return null;
        switch (pattern[i]) {
            .literal => |lit| if (!std.mem.eql(u8, lit, seg)) return null,
            .param => |name| {
                if (params.len >= Params.Capacity) return null;
                params.items[params.len] = .{ .name = name, .value = seg };
                params.len += 1;
            },
        }
        i += 1;
    }
    if (i != pattern.len) return null;
    return params;
}

test "exact match" {
    var r = Router.init(std.testing.allocator);
    defer r.deinit();
    const noop = struct {
        fn h(_: *const @import("request.zig").Request, _: *@import("response.zig").Response) !void {}
    }.h;
    try r.get("/baseline11", noop);
    try std.testing.expect(r.match(.GET, "/baseline11") != null);
    try std.testing.expect(r.match(.GET, "/baseline") == null);
    try std.testing.expect(r.match(.POST, "/baseline11") == null);
}

test "param capture" {
    var r = Router.init(std.testing.allocator);
    defer r.deinit();
    const noop = struct {
        fn h(_: *const @import("request.zig").Request, _: *@import("response.zig").Response) !void {}
    }.h;
    try r.get("/json/:count", noop);
    const m = r.match(.GET, "/json/42") orelse return error.NoMatch;
    try std.testing.expectEqualStrings("42", m.params.get("count").?);
}

test "static mount prefix" {
    var r = Router.init(std.testing.allocator);
    defer r.deinit();
    const noop = struct {
        fn h(_: *const @import("request.zig").Request, _: *@import("response.zig").Response) !void {}
    }.h;
    try r.staticMount("/static/", "/var/www/", noop);
    const m = r.match(.GET, "/static/some/file.txt") orelse return error.NoMatch;
    try std.testing.expectEqualStrings("/var/www/", m.static_root);
}
