//! GET /json/{count}?m=M : render `count` dataset items, each carrying
//! total = price * quantity * m.
//!
//! Note:
//! - The body is serialized on every request through jzon on .GENERATED, the
//!   write path its own benchmark puts at 4.31x the std-backed one. Nothing is
//!   memoized and nothing is pre-rendered at startup, so the work the json-h2c
//!   profile measures actually happens per request.

const std = @import("std");
const zix = @import("zix");

const dataset = @import("../shared/dataset.zig");
const response = @import("../shared/response.zig");

const jzon = zix.jzon;

// --------------------------------------------------------- //

pub const PATH = "/json";

/// Per-worker render buffer. Sized above the shipped fixture's worst case,
/// which the first load checks.
const BODY_BUF: usize = 128 * 1024;

/// One item as the response carries it: the fixture's own fields, plus the
/// per-request total.
const ResponseItem = struct {
    id: i64,
    name: []const u8,
    category: []const u8,
    price: i64,
    quantity: i64,
    active: bool,
    tags: []const []const u8,
    rating: dataset.Rating,
    total: u64,
};

const Body = struct {
    items: []const ResponseItem,
    count: u8,
};

threadlocal var tl_body: [BODY_BUF]u8 = undefined;
threadlocal var tl_items: [dataset.ITEM_COUNT]ResponseItem = undefined;

var g_dataset: dataset.Dataset = undefined;

/// Load state, so the fixture is read once however many workers ask at once.
/// A failed read is remembered, so a broken fixture is not re-read per request.
const Load = enum(u8) { UNSET, READY, FAILED };

var g_load: std.atomic.Value(u8) = .init(@intFromEnum(Load.UNSET));
var g_load_lock: std.atomic.Value(bool) = .init(false);

// --------------------------------------------------------- //

/// The fixture, read on the first request that needs it.
///
/// Note:
/// - Lazy rather than a startup call, so main stays the route table plus the
///   server. Workers race here on the first request and one of them wins the
///   lock, the rest see READY.
///
/// Return:
/// - []const dataset.Item
/// - null when the fixture is missing or does not match the schema
fn items() ?[]const dataset.Item {
    switch (@as(Load, @enumFromInt(g_load.load(.acquire)))) {
        .READY => return g_dataset.items,
        .FAILED => return null,
        .UNSET => {},
    }

    while (g_load_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
    defer g_load_lock.store(false, .release);

    switch (@as(Load, @enumFromInt(g_load.load(.acquire)))) {
        .READY => return g_dataset.items,
        .FAILED => return null,
        .UNSET => {},
    }

    g_dataset = dataset.load(std.heap.smp_allocator) catch {
        g_load.store(@intFromEnum(Load.FAILED), .release);

        return null;
    };
    if (dataset.bodyMaxBytes(g_dataset.items) > BODY_BUF) {
        g_load.store(@intFromEnum(Load.FAILED), .release);

        return null;
    }

    g_load.store(@intFromEnum(Load.READY), .release);

    return g_dataset.items;
}

// --------------------------------------------------------- //

/// Build the response value for (count, m) and render it into `out`.
fn renderBody(out: []u8, rows: []const dataset.Item, count: u8, multiplier: u64) !usize {
    for (rows[0..count], 0..) |item, index| {
        tl_items[index] = .{
            .id = item.id,
            .name = item.name,
            .category = item.category,
            .price = item.price,
            .quantity = item.quantity,
            .active = item.active,
            .tags = item.tags,
            .rating = item.rating,
            .total = @as(u64, @intCast(item.price * item.quantity)) * multiplier,
        };
    }

    return jzon.serialize(out, Body{ .items = tl_items[0..count], .count = count }, .{
        .strategy = .GENERATED,
    });
}

pub fn RESPONSE(req: *zix.Http2.Request, res: *zix.Http2.Response, ctx: *zix.Http2.Context) !void {
    // The PREFIX route also matches a bare /json with no trailing slash, which
    // would slice out of bounds below.
    if (req.path.len < PATH.len + 1) return response.badRequest(ctx.fd, ctx.sid);

    const rows = items() orelse return response.serviceUnavailable(ctx.fd, ctx.sid);

    const count = std.fmt.parseInt(u8, req.path[PATH.len + 1 ..], 10) catch return response.badRequest(ctx.fd, ctx.sid);
    if (count < 1 or count > dataset.ITEM_COUNT) return response.badRequest(ctx.fd, ctx.sid);

    const multiplier: u64 = if (req.queryParam("m")) |raw|
        std.fmt.parseInt(u64, raw, 10) catch 1
    else
        1;

    const body_len = renderBody(&tl_body, rows, count, multiplier) catch return response.badRequest(ctx.fd, ctx.sid);

    try res.sendJson(tl_body[0..body_len]);
}
