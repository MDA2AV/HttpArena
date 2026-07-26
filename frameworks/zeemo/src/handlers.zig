const std = @import("std");
const http = @import("http.zig");
const dataset = @import("dataset.zig");

pub const Response = struct {
    /// Full HTTP/1.1 response bytes, ready to send.
    bytes: []const u8,
    close: bool,
};

/// Top-level dispatcher. `out` is the per-connection write buffer.
pub fn handle(req: http.Request, ds: *const dataset.Dataset, out: []u8) Response {
    if (matchPath(req.path, "/baseline11"))
        return baseline11(req, out);
    if (matchPath(req.path, "/pipeline"))
        return pipelineHandler(req, out);
    if (matchJsonPath(req.path)) |count| {
        const m = parseMultiplier(req.query);
        return jsonHandler(count, m, ds, out);
    }
    return notFound(out, req.close);
}

fn pipelineHandler(req: http.Request, out: []u8) Response {
    const close_hdr: []const u8 = if (req.close) "Connection: close\r\n" else "";
    const n = std.fmt.bufPrint(
        out,
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n{s}\r\nok",
        .{close_hdr},
    ) catch unreachable;
    return .{ .bytes = n, .close = req.close };
}

fn matchPath(path: []const u8, p: []const u8) bool {
    return std.mem.eql(u8, path, p);
}

/// Matches `/json/{count}` where count ∈ [1, 50]. Returns the parsed count.
fn matchJsonPath(path: []const u8) ?u8 {
    if (!std.mem.startsWith(u8, path, "/json/")) return null;
    const tail = path["/json/".len..];
    if (tail.len == 0) return null;
    const n = std.fmt.parseInt(u8, tail, 10) catch return null;
    if (n < 1 or n > dataset.ItemCount) return null;
    return n;
}

fn parseMultiplier(query: []const u8) u64 {
    // Look for "m=NUMBER" anywhere in the query string.
    var it = std.mem.tokenizeScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "m=")) {
            return std.fmt.parseInt(u64, pair[2..], 10) catch 1;
        }
    }
    return 1;
}

fn baseline11(req: http.Request, out: []u8) Response {
    var sum: i64 = sumQuery(req.query);
    if (req.method == .POST and req.body.len > 0) {
        sum += parseIntLoose(req.body);
    }

    // Render the body first, then prepend headers with the correct
    // Content-Length.
    var body_buf: [32]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "{d}", .{sum}) catch unreachable;

    const close_hdr: []const u8 = if (req.close) "Connection: close\r\n" else "";
    const n = std.fmt.bufPrint(out,
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\n{s}\r\n{s}",
        .{ body.len, close_hdr, body }) catch unreachable;
    return .{ .bytes = n, .close = req.close };
}

fn sumQuery(q: []const u8) i64 {
    var sum: i64 = 0;
    var it = std.mem.tokenizeScalar(u8, q, '&');
    while (it.next()) |pair| {
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
            const v = pair[eq + 1 ..];
            sum += std.fmt.parseInt(i64, v, 10) catch 0;
        }
    }
    return sum;
}

fn parseIntLoose(s: []const u8) i64 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\r' or s[i] == '\n')) i += 1;
    var neg = false;
    if (i < s.len and s[i] == '-') { neg = true; i += 1; }
    var n: i64 = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        n = n * 10 + (s[i] - '0');
    }
    return if (neg) -n else n;
}

fn jsonHandler(count: u8, m: u64, ds: *const dataset.Dataset, out: []u8) Response {
    // Fixed-length header prefix: Content-Length is reserved at a known
    // offset and padded to 5 digits with leading zeros after we know the
    // body size. Leading zeros are RFC-compliant and let every response
    // start at out[0], which lets drainAndSend batch them contiguously
    // without a memmove.
    const HDR_PREFIX = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ";
    const CL_DIGITS = 5;
    const HDR_TAIL = "\r\n\r\n";
    const HEADERS_LEN = HDR_PREFIX.len + CL_DIGITS + HDR_TAIL.len;
    const CL_OFFSET = HDR_PREFIX.len;

    @memcpy(out[0..HDR_PREFIX.len], HDR_PREFIX);
    @memcpy(out[CL_OFFSET + CL_DIGITS ..][0..HDR_TAIL.len], HDR_TAIL);

    var pos: usize = HEADERS_LEN;
    pos = appendStr(out, pos, "{\"items\":[");
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (i > 0) {
            out[pos] = ',';
            pos += 1;
        }
        const item = ds.items[i];
        @memcpy(out[pos..][0..item.prefix.len], item.prefix);
        pos += item.prefix.len;
        pos = appendStr(out, pos, ",\"total\":");
        pos = appendInt(out, pos, item.pq * m);
        out[pos] = '}';
        pos += 1;
    }
    pos = appendStr(out, pos, "],\"count\":");
    pos = appendInt(out, pos, count);
    out[pos] = '}';
    pos += 1;

    const body_len = pos - HEADERS_LEN;
    var cl_buf: [CL_DIGITS]u8 = undefined;
    _ = std.fmt.bufPrint(&cl_buf, "{d:0>5}", .{body_len}) catch unreachable;
    @memcpy(out[CL_OFFSET..][0..CL_DIGITS], &cl_buf);

    return .{ .bytes = out[0..pos], .close = false };
}

fn notFound(out: []u8, close: bool) Response {
    const close_hdr: []const u8 = if (close) "Connection: close\r\n" else "";
    const n = std.fmt.bufPrint(out,
        "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 9\r\n{s}\r\nNot Found",
        .{close_hdr}) catch unreachable;
    return .{ .bytes = n, .close = close };
}

fn appendStr(out: []u8, pos: usize, s: []const u8) usize {
    @memcpy(out[pos..][0..s.len], s);
    return pos + s.len;
}

fn appendInt(out: []u8, pos: usize, n: u64) usize {
    var tmp: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
    @memcpy(out[pos..][0..s.len], s);
    return pos + s.len;
}

test "baseline GET" {
    var out: [256]u8 = undefined;
    const req: http.Request = .{ .method = .GET, .path = "/baseline11", .query = "a=13&b=42", .body = "", .close = false };
    var ds: dataset.Dataset = .{ .items = &.{}, .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer ds.deinit();
    const r = handle(req, &ds, &out);
    try std.testing.expect(std.mem.endsWith(u8, r.bytes, "\r\n\r\n55"));
}

test "baseline POST with body" {
    var out: [256]u8 = undefined;
    const req: http.Request = .{ .method = .POST, .path = "/baseline11", .query = "a=13&b=42", .body = "20", .close = false };
    var ds: dataset.Dataset = .{ .items = &.{}, .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer ds.deinit();
    const r = handle(req, &ds, &out);
    try std.testing.expect(std.mem.endsWith(u8, r.bytes, "\r\n\r\n75"));
}

test "json handler shape" {
    var out: [16384]u8 = undefined;
    var ds = try dataset.load(std.testing.allocator, "../HttpArena/data/dataset.json");
    defer ds.deinit();
    const req: http.Request = .{ .method = .GET, .path = "/json/5", .query = "m=3", .body = "", .close = false };
    const r = handle(req, &ds, &out);
    const body_start = std.mem.indexOf(u8, r.bytes, "\r\n\r\n").? + 4;
    const body = r.bytes[body_start..];
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 5), parsed.value.object.get("count").?.integer);
    const items = parsed.value.object.get("items").?.array;
    try std.testing.expectEqual(@as(usize, 5), items.items.len);
    // Item 0: Alpha Widget, price=328, quantity=15, m=3 → total=14760
    try std.testing.expectEqual(@as(i64, 14760), items.items[0].object.get("total").?.integer);
}
