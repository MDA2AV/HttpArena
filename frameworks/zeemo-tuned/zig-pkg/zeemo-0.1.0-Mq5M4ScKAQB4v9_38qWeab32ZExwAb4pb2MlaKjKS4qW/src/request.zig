//! Thin user-facing view over a parsed HTTP request, plus helpers for the
//! common parameter-extraction patterns the benchmark profiles need.

const std = @import("std");
const http = @import("http.zig");
const router = @import("router.zig");

pub const Request = struct {
    method: http.Method,
    /// Path without query (e.g. "/json/5").
    path: []const u8,
    /// Query string without leading '?' (e.g. "m=3&x=1"). Empty if none.
    raw_query: []const u8,
    /// Request body bytes. Empty for GET. For chunked or large bodies the
    /// streaming API on the server can yield additional chunks past this.
    body: []const u8,
    /// Set when the client sent `Connection: close`.
    close: bool,
    /// `Accept-Encoding` contained a `br` token.
    accepts_br: bool = false,
    /// `Accept-Encoding` contained a `gzip` token.
    accepts_gzip: bool = false,
    /// Path params captured by the router (`:name` segments).
    params: router.Params,

    pub fn query(self: *const Request, name: []const u8) ?[]const u8 {
        var it = std.mem.tokenizeScalar(u8, self.raw_query, '&');
        while (it.next()) |pair| {
            if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
                if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
            }
        }
        return null;
    }

    pub fn queryInt(self: *const Request, name: []const u8, comptime T: type) ?T {
        const v = self.query(name) orelse return null;
        return std.fmt.parseInt(T, v, 10) catch null;
    }

    pub fn param(self: *const Request, name: []const u8, comptime T: type) !T {
        const v = self.params.get(name) orelse return error.MissingParam;
        return std.fmt.parseInt(T, v, 10);
    }

    pub fn paramStr(self: *const Request, name: []const u8) ?[]const u8 {
        return self.params.get(name);
    }

    /// Returns the suffix of `path` after the given prefix, or null if the
    /// path doesn't start with that prefix. Useful in static-mount handlers
    /// to recover the filesystem-relative path.
    pub fn pathSuffix(self: *const Request, prefix: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, self.path, prefix)) return null;
        return self.path[prefix.len..];
    }
};

test "query parsing" {
    const req: Request = .{
        .method = .GET,
        .path = "/x",
        .raw_query = "a=13&b=42&m=3",
        .body = "",
        .close = false,
        .params = .{},
    };
    try std.testing.expectEqualStrings("13", req.query("a").?);
    try std.testing.expectEqualStrings("3", req.query("m").?);
    try std.testing.expect(req.query("z") == null);
    try std.testing.expectEqual(@as(?i64, 13), req.queryInt("a", i64));
}
