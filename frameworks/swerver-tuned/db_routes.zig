//! PostgreSQL-backed benchmark endpoints for the HttpArena swerver target.
//!
//!   GET /async-db?min&max&limit — `limit` independent random-id reads of the
//!     `items` table (ids drawn uniformly in [min,max]); JSON
//!     {"count":N,"items":[{...,"active":bool,"tags":[...],"rating":{...}}]}.
//!     Empty id range → zero matching rows → count=0 (anti-cheat).
//!   GET /fortunes — every `fortune` row plus one injected at request time,
//!     sorted by message, rendered as an HTML-escaped table.
//!
//! Both use the swerver park-and-resume PG API (swerver.db.pg.handler_api):
//! the handler issues a query and returns the park sentinel; the continuation
//! runs once the rows arrive and renders into `rctx.response_buf`.
const std = @import("std");
const swerver = @import("swerver");

const router = swerver.router;
const response_mod = swerver.response;
const pg_api = swerver.db.pg.handler_api;

pub fn register(app_router: *router.Router) !void {
    try app_router.get("/async-db", handleAsyncDb);
    try app_router.get("/fortunes", handleFortunes);
}

// ── shared helpers ──────────────────────────────────────────────────────────

fn dbUnavailable() response_mod.Response {
    return .{ .status = 503, .headers = &[_]response_mod.Header{}, .body = .{ .bytes = "database not configured" } };
}

fn dbFailed() response_mod.Response {
    return .{ .status = 500, .headers = &[_]response_mod.Header{}, .body = .{ .bytes = "database query failed" } };
}

fn appendBytes(buf: []u8, w: usize, bytes: []const u8) ?usize {
    if (buf.len - w < bytes.len) return null;
    @memcpy(buf[w .. w + bytes.len], bytes);
    return w + bytes.len;
}

fn appendHtmlEscaped(buf: []u8, start: usize, text: []const u8) ?usize {
    var w = start;
    for (text) |c| {
        const rep: []const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => {
                if (w == buf.len) return null;
                buf[w] = c;
                w += 1;
                continue;
            },
        };
        w = appendBytes(buf, w, rep) orelse return null;
    }
    return w;
}

/// Append a JSON-escaped string body (no surrounding quotes).
fn appendJsonEscaped(buf: []u8, start: usize, text: []const u8) ?usize {
    var w = start;
    for (text) |c| {
        switch (c) {
            '"' => {
                w = appendBytes(buf, w, "\\\"") orelse return null;
            },
            '\\' => {
                w = appendBytes(buf, w, "\\\\") orelse return null;
            },
            '\n' => {
                w = appendBytes(buf, w, "\\n") orelse return null;
            },
            '\r' => {
                w = appendBytes(buf, w, "\\r") orelse return null;
            },
            '\t' => {
                w = appendBytes(buf, w, "\\t") orelse return null;
            },
            else => {
                if (c < 0x20) {
                    var esc: [6]u8 = undefined;
                    const s = std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{c}) catch return null;
                    w = appendBytes(buf, w, s) orelse return null;
                } else {
                    if (w == buf.len) return null;
                    buf[w] = c;
                    w += 1;
                }
            },
        }
    }
    return w;
}

fn getParam(path: []const u8, name: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, path, '?') orelse return null;
    var it = std.mem.splitScalar(u8, path[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

fn getU32(path: []const u8, name: []const u8, dflt: u32) u32 {
    const v = getParam(path, name) orelse return dflt;
    return std.fmt.parseInt(u32, v, 10) catch dflt;
}

/// A JSONB column read in binary result format is a 1-byte version header
/// (0x01) followed by the JSON text. Drop the header to recover valid JSON.
fn jsonbText(raw: []const u8) []const u8 {
    return if (raw.len > 0 and raw[0] == 0x01) raw[1..] else raw;
}

// ── /async-db ───────────────────────────────────────────────────────────────
//
// Per the spec: GET /async-db?min&max&limit runs ONE range query
//   SELECT ... FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3
// (min/max are PRICE bounds, not ids; limit defaults 50, clamped 1..50;
// items has 100k rows, no price index → sequential scan). rating_score /
// rating_count are restructured into a nested "rating" object. Response:
// {"items":[...],"count":N}.

const ASYNC_MAX = 50;
const AsyncStash = struct {};

fn handleAsyncDb(ctx: *router.HandlerContext) response_mod.Response {
    const min = getU32(ctx.request.path, "min", 10);
    const max = getU32(ctx.request.path, "max", 50);
    var limit = getU32(ctx.request.path, "limit", 50);
    if (limit < 1) limit = 1;
    if (limit > ASYNC_MAX) limit = ASYNC_MAX;

    var min_buf: [12]u8 = undefined;
    var max_buf: [12]u8 = undefined;
    var lim_buf: [12]u8 = undefined;
    const min_s = std.fmt.bufPrint(&min_buf, "{d}", .{min}) catch unreachable;
    const max_s = std.fmt.bufPrint(&max_buf, "{d}", .{max}) catch unreachable;
    const lim_s = std.fmt.bufPrint(&lim_buf, "{d}", .{limit}) catch unreachable;
    return ctx.pg.query(
        "select id, name, category, price, quantity, active, tags, rating_score, rating_count from items where price between $1 and $2 limit $3",
        &[_]?[]const u8{ min_s, max_s, lim_s },
        AsyncStash,
        .{},
        onAsyncDb,
    ) catch dbUnavailable();
}

const Item = struct {
    id: i32,
    name: []const u8,
    category: []const u8,
    price: i32,
    quantity: i32,
    active: bool,
    tags: []const u8, // JSONB rendered as text → already a JSON array literal
    score: i32,
    rating_count: i32,
};

fn onAsyncDb(rctx: *pg_api.ResumeContext) response_mod.Response {
    const res = rctx.result catch return dbFailed();

    // Rows borrow the result frames — valid for the life of this continuation.
    var items: [ASYNC_MAX]Item = undefined;
    var n: usize = 0;
    var rows = res.rows();
    while (rows.next()) |row| {
        if (n == ASYNC_MAX) return dbFailed();
        items[n] = .{
            .id = row.int4(0) catch return dbFailed(),
            .name = row.text(1) catch return dbFailed(),
            .category = row.text(2) catch return dbFailed(),
            .price = row.int4(3) catch return dbFailed(),
            .quantity = row.int4(4) catch return dbFailed(),
            .active = row.boolean(5) catch return dbFailed(),
            // tags is JSONB; the client receives columns in binary format, and
            // JSONB binary is a 1-byte version prefix (0x01) followed by the
            // JSON text. Strip the prefix so the embedded value is valid JSON
            // (without this the rendered response is malformed at "tags":).
            .tags = jsonbText(row.text(6) catch return dbFailed()),
            .score = row.int4(7) catch return dbFailed(),
            .rating_count = row.int4(8) catch return dbFailed(),
        };
        n += 1;
    }

    const buf = rctx.response_buf;
    var w: usize = 0;
    w = appendBytes(buf, w, "{\"items\":[") orelse return dbFailed();
    for (items[0..n], 0..) |it, idx| {
        if (idx != 0) w = appendBytes(buf, w, ",") orelse return dbFailed();
        var pre: [48]u8 = undefined;
        const pre_str = std.fmt.bufPrint(&pre, "{{\"id\":{d},\"name\":\"", .{it.id}) catch return dbFailed();
        w = appendBytes(buf, w, pre_str) orelse return dbFailed();
        w = appendJsonEscaped(buf, w, it.name) orelse return dbFailed();
        w = appendBytes(buf, w, "\",\"category\":\"") orelse return dbFailed();
        w = appendJsonEscaped(buf, w, it.category) orelse return dbFailed();
        var mid: [96]u8 = undefined;
        const mid_str = std.fmt.bufPrint(&mid, "\",\"price\":{d},\"quantity\":{d},\"active\":{s},\"tags\":", .{
            it.price, it.quantity, if (it.active) @as([]const u8, "true") else "false",
        }) catch return dbFailed();
        w = appendBytes(buf, w, mid_str) orelse return dbFailed();
        w = appendBytes(buf, w, it.tags) orelse return dbFailed();
        var tail: [64]u8 = undefined;
        const tail_str = std.fmt.bufPrint(&tail, ",\"rating\":{{\"score\":{d},\"count\":{d}}}}}", .{ it.score, it.rating_count }) catch return dbFailed();
        w = appendBytes(buf, w, tail_str) orelse return dbFailed();
    }
    var tailb: [24]u8 = undefined;
    const tail_str2 = std.fmt.bufPrint(&tailb, "],\"count\":{d}}}", .{n}) catch return dbFailed();
    w = appendBytes(buf, w, tail_str2) orelse return dbFailed();

    return .{
        .status = 200,
        .headers = &[_]response_mod.Header{.{ .name = "Content-Type", .value = "application/json" }},
        .body = .{ .bytes = buf[0..w] },
    };
}

// ── /fortunes ───────────────────────────────────────────────────────────────

const MAX_FORTUNES = 256;
const EXTRA_FORTUNE = "Additional fortune added at request time.";
const FortuneStash = struct {};

const Fortune = struct {
    id: i32,
    message: []const u8,

    fn lessThan(_: void, a: Fortune, b: Fortune) bool {
        return std.mem.order(u8, a.message, b.message) == .lt;
    }
};

fn handleFortunes(ctx: *router.HandlerContext) response_mod.Response {
    return ctx.pg.query(
        "select id, message from fortune",
        &.{},
        FortuneStash,
        .{},
        onFortunes,
    ) catch dbUnavailable();
}

fn onFortunes(rctx: *pg_api.ResumeContext) response_mod.Response {
    const res = rctx.result catch return dbFailed();

    var fortunes: [MAX_FORTUNES]Fortune = undefined;
    var count: usize = 0;
    fortunes[count] = .{ .id = 0, .message = EXTRA_FORTUNE };
    count += 1;
    var rows = res.rows();
    while (rows.next()) |row| {
        if (count == MAX_FORTUNES) return dbFailed();
        fortunes[count] = .{
            .id = row.int4(0) catch return dbFailed(),
            .message = row.text(1) catch return dbFailed(),
        };
        count += 1;
    }
    std.mem.sort(Fortune, fortunes[0..count], {}, Fortune.lessThan);

    // The 200-row table renders to ~25-30 KB — past the 24 KB resume
    // response_buf. Render into the resume arena (a ~64 KB pool buffer),
    // which stays valid until the queued response has been copied out.
    const buf = rctx.arena.allocator().alloc(u8, 60 * 1024) catch return dbFailed();
    var w: usize = 0;
    w = appendBytes(buf, w, "<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>") orelse return dbFailed();
    for (fortunes[0..count]) |f| {
        var num_buf: [12]u8 = undefined;
        const id_str = std.fmt.bufPrint(&num_buf, "{d}", .{f.id}) catch return dbFailed();
        w = appendBytes(buf, w, "<tr><td>") orelse return dbFailed();
        w = appendBytes(buf, w, id_str) orelse return dbFailed();
        w = appendBytes(buf, w, "</td><td>") orelse return dbFailed();
        w = appendHtmlEscaped(buf, w, f.message) orelse return dbFailed();
        w = appendBytes(buf, w, "</td></tr>") orelse return dbFailed();
    }
    w = appendBytes(buf, w, "</table></body></html>") orelse return dbFailed();

    return .{
        .status = 200,
        .headers = &[_]response_mod.Header{.{ .name = "Content-Type", .value = "text/html; charset=utf-8" }},
        .body = .{ .bytes = buf[0..w] },
    };
}
