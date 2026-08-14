//! GET /json/{count}?m=M : render `count` dataset items, each carrying
//! total = price * quantity * m.
//!
//! Note:
//! - The body is serialized on every request through jzon on .GENERATED, the
//!   write path its own benchmark puts at 4.31x the std-backed one. Nothing is
//!   memoized and nothing is pre-rendered at startup, so the work the json,
//!   json-comp, and json-tls profiles measure actually happens per request.
//! - jzon renders into a caller-owned buffer, so the cleartext path renders
//!   straight into the engine's send region with no copy in between.

const std = @import("std");
const zix = @import("zix");

const dataset = @import("../shared/dataset.zig");
const response = @import("../shared/response.zig");

const jzon = zix.jzon;

// --------------------------------------------------------- //

pub const PATH = "/json";

/// Room in front of the body for the response head, so head and body leave as
/// one slice.
const HEAD_RESERVE: usize = 96;

/// Per-worker render buffer. Sized above the shipped fixture's worst case,
/// which init checks.
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

threadlocal var tl_resp_buf: [HEAD_RESERVE + BODY_BUF]u8 = undefined;
threadlocal var tl_items: [dataset.ITEM_COUNT]ResponseItem = undefined;

var g_dataset: dataset.Dataset = undefined;
var g_body_max: usize = 0;

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
    g_body_max = dataset.bodyMaxBytes(g_dataset.items);
    if (g_body_max > BODY_BUF) {
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

pub fn RESPONSE(req: *zix.Http1.Request, _: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    const head = req.head;
    const fd = req.fd;

    // The PREFIX route also matches a bare /json with no trailing slash, which
    // would slice out of bounds below.
    if (head.path.len < PATH.len + 1) {
        try response.badRequest(fd);
        return;
    }

    const rows = items() orelse {
        try response.serviceUnavailable(fd);
        return;
    };

    const count = std.fmt.parseInt(u8, head.path[PATH.len + 1 ..], 10) catch {
        try response.badRequest(fd);
        return;
    };
    if (count < 1 or count > dataset.ITEM_COUNT) {
        try response.badRequest(fd);
        return;
    }

    const multiplier: u64 = if (zix.Http1.queryParam(head, "m")) |raw|
        std.fmt.parseInt(u64, raw, 10) catch 1
    else
        1;

    const accept = zix.Http1.acceptEncoding(head) orelse "";
    const want_gzip = std.mem.indexOf(u8, accept, "gzip") != null;

    // Cleartext path: render straight into the engine's send buffer, which
    // puts the head in front. The body is written once, with no copy.
    if (!want_gzip) {
        if (zix.Http1.responseReserve(fd, g_body_max)) |region| {
            const body_len = renderBody(region, rows, count, multiplier) catch {
                try response.badRequest(fd);
                return;
            };

            try zix.Http1.responseCommit(fd, 200, "application/json", body_len);
            return;
        }
    }

    const body = tl_resp_buf[HEAD_RESERVE..];
    const body_len = renderBody(body, rows, count, multiplier) catch {
        try response.badRequest(fd);
        return;
    };

    // Compress the body just rendered, every request.
    if (want_gzip) {
        try zix.Http1.sendGzipFD(fd, 200, "application/json", body[0..body_len]);
        return;
    }

    // The head is built right behind the body, so both leave as one slice. A
    // head that will not render falls back to the engine's own json sender,
    // which builds its own.
    var head_buf: [HEAD_RESERVE]u8 = undefined;
    const rendered_head = std.fmt.bufPrint(&head_buf, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{body_len}) catch {
        try zix.Http1.sendJsonFD(fd, 200, body[0..body_len]);
        return;
    };

    const start = HEAD_RESERVE - rendered_head.len;
    @memcpy(tl_resp_buf[start..HEAD_RESERVE], rendered_head);

    try zix.Http1.writeAllFD(fd, tl_resp_buf[start .. HEAD_RESERVE + body_len]);
}
