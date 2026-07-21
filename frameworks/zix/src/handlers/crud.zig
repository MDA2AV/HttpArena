//! /crud/items : GET lists (paged, category filter) or reads one id, POST
//! creates, PUT updates. A cache hit (crudcache.zig) answers on the engine
//! worker, otherwise queues a Job on the fd's postgrez shard thread
//! (dbpg.zig).

const std = @import("std");
const zix = @import("zix");

const dbpg = @import("../shared/dbpg.zig");

const response = @import("../shared/response.zig");
const crudcache = @import("../shared/crudcache.zig");

// --------------------------------------------------------- //

pub const PATH = "/crud/items";

const CRUD_LIST_LIMIT_DEFAULT: i64 = 10;
const CRUD_LIST_LIMIT_MAX: i64 = 100;

// Per-worker scratch for the engine-side cache reads.
threadlocal var tl_db_body_buf: [32 * 1024]u8 = undefined;

// Per-engine-worker arena for the crud POST/PUT JSON body parse.
threadlocal var tl_crud_arena: ?std.heap.ArenaAllocator = null;

const CrudBody = struct {
    id: i64 = 0,
    name: []const u8 = "",
    category: []const u8 = "",
    price: i64 = 0,
    quantity: i64 = 0,
};

// --------------------------------------------------------- //

fn crudList(head: *const zix.Http1.ParsedHead, fd: std.posix.fd_t) void {
    const category = zix.Http1.queryParam(head, "category") orelse "";
    var page: i64 = if (zix.Http1.queryParam(head, "page")) |raw| std.fmt.parseInt(i64, raw, 10) catch 1 else 1;
    var limit: i64 = if (zix.Http1.queryParam(head, "limit")) |raw| std.fmt.parseInt(i64, raw, 10) catch CRUD_LIST_LIMIT_DEFAULT else CRUD_LIST_LIMIT_DEFAULT;
    if (page < 1) page = 1;
    if (limit < 1) limit = CRUD_LIST_LIMIT_DEFAULT;
    if (limit > CRUD_LIST_LIMIT_MAX) limit = CRUD_LIST_LIMIT_MAX;
    if (category.len > dbpg.CATEGORY_MAX) return response.badRequest(fd);

    // list-page cache first: a hit answers on the engine worker
    const list_key = crudcache.listKey(category, page, limit);
    if (crudcache.listGet(list_key, &tl_db_body_buf)) |len| {
        zix.Http1.sendJsonFD(fd, 200, tl_db_body_buf[0..len]) catch {};

        return;
    }

    var job: dbpg.Job = .{ .CRUD_LIST = .{
        .fd = fd,
        .page = page,
        .limit = limit,
        .category_len = @intCast(category.len),
        .category_buf = undefined,
    } };
    @memcpy(job.CRUD_LIST.category_buf[0..category.len], category);

    if (!dbpg.submitJob(head, job)) response.serviceUnavailable(fd);
}

fn parseCrudBody(body: []const u8) ?CrudBody {
    if (tl_crud_arena == null) tl_crud_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);

    const arena = &tl_crud_arena.?;
    _ = arena.reset(.retain_capacity);

    return std.json.parseFromSliceLeaky(CrudBody, arena.allocator(), body, .{
        .ignore_unknown_fields = true,
    }) catch null;
}

fn crudCreate(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    const item = parseCrudBody(body) orelse return response.badRequest(fd);
    if (item.id < 1 or item.name.len == 0) return response.badRequest(fd);
    if (item.name.len > dbpg.NAME_MAX or item.category.len > dbpg.CATEGORY_MAX) return response.badRequest(fd);

    var job: dbpg.Job = .{ .CRUD_CREATE = .{
        .fd = fd,
        .id = item.id,
        .price = item.price,
        .quantity = item.quantity,
        .name_len = @intCast(item.name.len),
        .category_len = @intCast(item.category.len),
        .name_buf = undefined,
        .category_buf = undefined,
    } };
    @memcpy(job.CRUD_CREATE.name_buf[0..item.name.len], item.name);
    @memcpy(job.CRUD_CREATE.category_buf[0..item.category.len], item.category);

    if (!dbpg.submitJob(head, job)) response.serviceUnavailable(fd);
}

/// 200 JSON response with the X-Cache header the crud cache check reads.
fn sendCrudBody(fd: std.posix.fd_t, body: []const u8, cache_state: []const u8) void {
    var hdr_buf: [128]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Cache: {s}\r\nContent-Length: {d}\r\n\r\n", .{ cache_state, body.len }) catch return;

    zix.Http1.writeAllFD(fd, hdr) catch return;
    zix.Http1.writeAllFD(fd, body) catch {};
}

fn crudUpdate(head: *const zix.Http1.ParsedHead, id: i64, body: []const u8, fd: std.posix.fd_t) void {
    const item = parseCrudBody(body) orelse return response.badRequest(fd);
    if (item.name.len > dbpg.NAME_MAX or item.category.len > dbpg.CATEGORY_MAX) return response.badRequest(fd);

    var job: dbpg.Job = .{ .CRUD_UPDATE = .{
        .fd = fd,
        .id = id,
        .price = item.price,
        .quantity = item.quantity,
        .name_len = @intCast(item.name.len),
        .category_len = @intCast(item.category.len),
        .name_buf = undefined,
        .category_buf = undefined,
    } };
    @memcpy(job.CRUD_UPDATE.name_buf[0..item.name.len], item.name);
    @memcpy(job.CRUD_UPDATE.category_buf[0..item.category.len], item.category);

    if (!dbpg.submitJob(head, job)) response.serviceUnavailable(fd);
}


// --------------------------------------------------------- //

pub fn RESPONSE(
    req: *zix.Http1.Request,
    _: *zix.Http1.Response,
    _: *zix.Http1.Context
) !void {
    const head = req.head;
    const body = try req.body();
    const fd = req.fd;

    const sub = head.path[PATH.len..];

    if (sub.len == 0) {
        if (std.mem.eql(u8, head.method, "GET")) return crudList(head, fd);
        if (std.mem.eql(u8, head.method, "POST")) return crudCreate(head, body, fd);

        return response.notFound(fd);
    }

    if (sub[0] != '/' or sub.len == 1) return response.notFound(fd);
    const id = std.fmt.parseInt(i64, sub[1..], 10) catch return response.badRequest(fd);

    if (std.mem.eql(u8, head.method, "GET")) {
        // in-process cache first: a HIT answers on the engine worker and
        // never becomes a job
        if (crudcache.get(id, &tl_db_body_buf)) |len| {
            sendCrudBody(fd, tl_db_body_buf[0..len], "HIT");

            return;
        }

        if (!dbpg.submitJob(head, .{ .CRUD_GET = .{ .fd = fd, .id = id } })) response.serviceUnavailable(fd);

        return;
    }
    if (std.mem.eql(u8, head.method, "PUT")) return crudUpdate(head, id, body, fd);

    return response.notFound(fd);
}
