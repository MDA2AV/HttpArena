//! /crud/items : GET lists a page or reads one id, POST creates, PUT updates.
//!
//! Note:
//! - A single-id read checks the row cache first (crudcache.zig) and answers
//!   X-Cache HIT without touching the database. That cache-aside IS the crud
//!   profile: its validator requires MISS on the first read of an id, HIT on
//!   the second, and MISS again after a write. Everything else here queues a
//!   Job on this worker's postgres lane.
//! - The cache holds a decoded row, never a rendered HTTP response. The status
//!   line, headers, and framing are built on every reply.
//! - The create and update body is decoded through jzon on .GENERATED, the same
//!   read path the /json route's fixture load uses.

const std = @import("std");
const zix = @import("zix");

const crudcache = @import("../shared/crudcache.zig");
const dbpg = @import("../shared/dbpg.zig");
const response = @import("../shared/response.zig");

const jzon = zix.jzon;

// --------------------------------------------------------- //

pub const PATH = "/crud/items";

const LIST_LIMIT_DEFAULT: i64 = 10;
const LIST_LIMIT_MAX: i64 = 100;

/// Per-worker scratch for a cached row read.
threadlocal var tl_row_buf: [32 * 1024]u8 = undefined;

/// Per-worker arena for the create and update body parse.
threadlocal var tl_arena: ?std.heap.ArenaAllocator = null;

/// The fields a create or update body may carry.
const CrudBody = struct {
    id: i64 = 0,
    name: []const u8 = "",
    category: []const u8 = "",
    price: i64 = 0,
    quantity: i64 = 0,
};

// --------------------------------------------------------- //

fn queryInt(head: *const zix.Http1.ParsedHead, name: []const u8, fallback: i64) i64 {
    const raw = zix.Http1.queryParam(head, name) orelse return fallback;

    return std.fmt.parseInt(i64, raw, 10) catch fallback;
}

fn parseBody(body: []const u8) ?CrudBody {
    if (tl_arena == null) tl_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);

    const arena = &tl_arena.?;
    _ = arena.reset(.retain_capacity);

    // BORROW is safe: the caller copies name and category into the job's fixed
    // buffers before returning, so `body` outlives everything pointing into it.
    return jzon.deserialize(CrudBody, arena.allocator(), body, .{
        .strategy = .GENERATED,
        .strings = .BORROW,
        .unknown = .SKIP,
    }) catch null;
}

// --------------------------------------------------------- //

fn crudList(head: *const zix.Http1.ParsedHead, fd: std.posix.fd_t) !void {
    const category = zix.Http1.queryParam(head, "category") orelse "";
    if (category.len > dbpg.CATEGORY_MAX) {
        try response.badRequest(fd);
        return;
    }

    const page = @max(queryInt(head, "page", 1), 1);
    const limit = std.math.clamp(queryInt(head, "limit", LIST_LIMIT_DEFAULT), 1, LIST_LIMIT_MAX);

    var job: dbpg.Job = .{ .CRUD_LIST = .{
        .fd = fd,
        .page = page,
        .limit = limit,
        .category_len = @intCast(category.len),
        .category_buf = undefined,
    } };
    @memcpy(job.CRUD_LIST.category_buf[0..category.len], category);

    if (!dbpg.submitJob(head, job)) try response.serviceUnavailable(fd);
}

fn crudCreate(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) !void {
    const item = parseBody(body) orelse {
        try response.badRequest(fd);
        return;
    };
    if (item.id < 1 or item.name.len == 0) {
        try response.badRequest(fd);
        return;
    }
    if (item.name.len > dbpg.NAME_MAX or item.category.len > dbpg.CATEGORY_MAX) {
        try response.badRequest(fd);
        return;
    }

    var job: dbpg.Job = .{ .CRUD_CREATE = writeJob(fd, item.id, item) };
    @memcpy(job.CRUD_CREATE.name_buf[0..item.name.len], item.name);
    @memcpy(job.CRUD_CREATE.category_buf[0..item.category.len], item.category);

    if (!dbpg.submitJob(head, job)) try response.serviceUnavailable(fd);
}

fn crudUpdate(head: *const zix.Http1.ParsedHead, id: i64, body: []const u8, fd: std.posix.fd_t) !void {
    const item = parseBody(body) orelse {
        try response.badRequest(fd);
        return;
    };
    if (item.name.len > dbpg.NAME_MAX or item.category.len > dbpg.CATEGORY_MAX) {
        try response.badRequest(fd);
        return;
    }

    var job: dbpg.Job = .{ .CRUD_UPDATE = writeJob(fd, id, item) };
    @memcpy(job.CRUD_UPDATE.name_buf[0..item.name.len], item.name);
    @memcpy(job.CRUD_UPDATE.category_buf[0..item.category.len], item.category);

    if (!dbpg.submitJob(head, job)) try response.serviceUnavailable(fd);
}

/// The scalar half of a write job. The caller copies the strings in, since
/// they cannot be returned by value from here.
fn writeJob(fd: std.posix.fd_t, id: i64, item: CrudBody) dbpg.CrudWrite {
    return .{
        .fd = fd,
        .id = id,
        .price = item.price,
        .quantity = item.quantity,
        .name_len = @intCast(item.name.len),
        .category_len = @intCast(item.category.len),
        .name_buf = undefined,
        .category_buf = undefined,
    };
}

// --------------------------------------------------------- //

pub fn RESPONSE(req: *zix.Http1.Request, _: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    const head = req.head;
    const body = try req.body();
    const fd = req.fd;

    const sub = head.path[PATH.len..];

    if (sub.len == 0) {
        if (req.method() == .GET) {
            try crudList(head, fd);
            return;
        }
        if (req.method() == .POST) {
            try crudCreate(head, body, fd);
            return;
        }

        try response.notFound(fd);
        return;
    }

    if (sub[0] != '/' or sub.len == 1) {
        try response.notFound(fd);
        return;
    }

    const id = std.fmt.parseInt(i64, sub[1..], 10) catch {
        try response.badRequest(fd);
        return;
    };

    if (req.method() == .GET) {
        // A cache hit answers on this worker and never becomes a job.
        if (crudcache.get(id, &tl_row_buf)) |len| {
            dbpg.sendCrudBody(fd, tl_row_buf[0..len], "HIT");

            return;
        }

        if (!dbpg.submitJob(head, .{ .CRUD_GET = .{ .fd = fd, .id = id } })) try response.serviceUnavailable(fd);

        return;
    }
    if (req.method() == .PUT) {
        try crudUpdate(head, id, body, fd);
        return;
    }

    try response.notFound(fd);
}
