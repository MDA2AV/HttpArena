const std = @import("std");
const swerver = @import("swerver");

const router = swerver.router;
const response_mod = swerver.response;
const clock = swerver.runtime.clock;

// ── Dataset ──────────────────────────────────────────────────────

const Rating = struct { score: i64 = 0, count: i64 = 0 };

// Shape parsed from dataset.json (the validator requires the full item
// schema: active, tags, rating in addition to the scalar fields).
const ParseItem = struct {
    id: i64,
    name: []const u8,
    category: []const u8,
    price: i64,
    quantity: i64,
    active: bool = false,
    tags: []const []const u8 = &.{},
    rating: Rating = .{},
};

const DatasetItem = struct {
    id: i64,
    name: []const u8,
    category: []const u8,
    price: i64,
    quantity: i64,
    active: bool,
    // tags rendered once as a JSON array string (e.g. ["a","b"]) into a
    // static pool, so handleJson can emit it directly.
    tags_text: []const u8,
    rating: Rating,
};

const MAX_ITEMS = 64;
var dataset_items: [MAX_ITEMS]DatasetItem = undefined;
var dataset_len: usize = 0;

fn loadDataset() void {
    var path_z: [64]u8 = undefined;
    const dpath = "/data/dataset.json";
    @memcpy(path_z[0..dpath.len], dpath);
    path_z[dpath.len] = 0;
    const path_ptr: [*:0]const u8 = @ptrCast(&path_z);
    const fd = std.posix.openatZ(std.posix.AT.FDCWD, path_ptr, .{ .ACCMODE = .RDONLY }, 0) catch return;
    defer clock.closeFd(fd);
    var raw: [32768]u8 = undefined;
    const n = std.posix.read(fd, &raw) catch return;
    if (n == 0) return;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const items = std.json.parseFromSliceLeaky(
        []ParseItem,
        arena.allocator(),
        raw[0..n],
        .{ .ignore_unknown_fields = true },
    ) catch return;

    const count = @min(items.len, MAX_ITEMS);
    for (items[0..count], 0..) |item, i| {
        // Copy name/category and render tags into static pools so they
        // outlive the parse arena.
        const ns = name_pool_off;
        @memcpy(name_pool[ns .. ns + item.name.len], item.name);
        name_pool_off += item.name.len;

        const cs = cat_pool_off;
        @memcpy(cat_pool[cs .. cs + item.category.len], item.category);
        cat_pool_off += item.category.len;

        const ts = tags_pool_off;
        var to = ts;
        tags_pool[to] = '[';
        to += 1;
        for (item.tags, 0..) |tag, ti| {
            if (ti > 0) {
                tags_pool[to] = ',';
                to += 1;
            }
            tags_pool[to] = '"';
            to += 1;
            @memcpy(tags_pool[to .. to + tag.len], tag);
            to += tag.len;
            tags_pool[to] = '"';
            to += 1;
        }
        tags_pool[to] = ']';
        to += 1;
        tags_pool_off = to;

        dataset_items[i] = .{
            .id = item.id,
            .name = name_pool[ns .. ns + item.name.len],
            .category = cat_pool[cs .. cs + item.category.len],
            .price = item.price,
            .quantity = item.quantity,
            .active = item.active,
            .tags_text = tags_pool[ts..to],
            .rating = item.rating,
        };
    }
    dataset_len = count;
}

// Flat string pools for dataset names/categories (outlive the parse arena).
var name_pool: [1024]u8 = undefined;
var name_pool_off: usize = 0;
var cat_pool: [1024]u8 = undefined;
var cat_pool_off: usize = 0;
var tags_pool: [8192]u8 = undefined;
var tags_pool_off: usize = 0;

// ── Handlers ─────────────────────────────────────────────────────

fn handleHealth(_: *router.HandlerContext) response_mod.Response {
    return .{
        .status = 200,
        .headers = &[_]response_mod.Header{},
        .body = .none,
    };
}

fn handleEchoGet(_: *router.HandlerContext) response_mod.Response {
    return .{
        .status = 200,
        .headers = &[_]response_mod.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .body = .{ .bytes = "{\"status\":\"ok\"}" },
    };
}

fn handleEchoPost(ctx: *router.HandlerContext) response_mod.Response {
    if (ctx.request.body.len() == 0) return handleEchoGet(ctx);
    const body_slice = ctx.request.body.sliceOrNull() orelse {
        const buf = ctx.request.body.copyTo(ctx.response_buf) orelse return .{
            .status = 413,
            .headers = &[_]response_mod.Header{},
            .body = .{ .bytes = "Body too large to echo" },
        };
        return .{
            .status = 200,
            .headers = &[_]response_mod.Header{
                .{ .name = "Content-Type", .value = "application/json" },
            },
            .body = .{ .bytes = buf },
        };
    };
    return .{
        .status = 200,
        .headers = &[_]response_mod.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .body = .{ .bytes = body_slice },
    };
}

fn handlePlaintext(_: *router.HandlerContext) response_mod.Response {
    return .{
        .status = 200,
        .headers = &[_]response_mod.Header{
            .{ .name = "Content-Type", .value = "text/plain" },
        },
        .body = .{ .bytes = "Hello, World!" },
    };
}

fn handlePipeline(_: *router.HandlerContext) response_mod.Response {
    return .{
        .status = 200,
        .headers = &[_]response_mod.Header{
            .{ .name = "Content-Type", .value = "text/plain" },
        },
        .body = .{ .bytes = "ok" },
    };
}

fn handleBaseline(ctx: *router.HandlerContext) response_mod.Response {
    var sum: i64 = 0;
    if (std.mem.indexOfScalar(u8, ctx.request.path, '?')) |q_start| {
        const query = ctx.request.path[q_start + 1 ..];
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |pair| {
            if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
                sum += std.fmt.parseInt(i64, pair[eq + 1 ..], 10) catch 0;
            }
        }
    }
    if (ctx.request.method == .POST and ctx.request.body.len() > 0) {
        const body_bytes = ctx.request.body.sliceOrNull() orelse "";
        const trimmed = std.mem.trim(u8, body_bytes, " \t\r\n");
        sum += std.fmt.parseInt(i64, trimmed, 10) catch 0;
    }
    const body = std.fmt.bufPrint(ctx.response_buf, "{d}", .{sum}) catch "0";
    return .{
        .status = 200,
        .headers = &[_]response_mod.Header{
            .{ .name = "Content-Type", .value = "text/plain" },
        },
        .body = .{ .bytes = body },
    };
}

fn handleUpload(ctx: *router.HandlerContext) response_mod.Response {
    const body = std.fmt.bufPrint(ctx.response_buf, "{d}", .{ctx.request.body.len()}) catch "0";
    return .{
        .status = 200,
        .headers = &[_]response_mod.Header{
            .{ .name = "Content-Type", .value = "text/plain" },
        },
        .body = .{ .bytes = body },
    };
}

/// GET /json/:count?m=X — return `count` items with total = price * quantity * m
fn handleJson(ctx: *router.HandlerContext) response_mod.Response {
    const count_str = ctx.getParam("count") orelse "50";
    const count = @min(
        std.fmt.parseInt(usize, count_str, 10) catch 50,
        dataset_len,
    );

    var m: i64 = 1;
    if (std.mem.indexOfScalar(u8, ctx.request.path, '?')) |q_start| {
        const query = ctx.request.path[q_start + 1 ..];
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |pair| {
            if (std.mem.startsWith(u8, pair, "m=")) {
                m = std.fmt.parseInt(i64, pair[2..], 10) catch 1;
            }
        }
    }

    // Build into a process-global buffer rather than ctx.response_buf (8 KiB):
    // the full item schema (active/tags/rating) pushes /json/50 past 8 KiB.
    // Safe because the response is encoded into the connection write buffer
    // synchronously before the next request runs (single-threaded per worker).
    const buf = json_buf[0..];
    var off: usize = 0;

    const header = std.fmt.bufPrint(buf[off..], "{{\"count\":{d},\"items\":[", .{count}) catch
        return jsonError();
    off += header.len;

    for (dataset_items[0..count], 0..) |item, i| {
        if (i > 0) {
            buf[off] = ',';
            off += 1;
        }
        const total = item.price * item.quantity * m;
        const entry = std.fmt.bufPrint(buf[off..], "{{\"id\":{d},\"name\":\"{s}\",\"category\":\"{s}\",\"price\":{d},\"quantity\":{d},\"active\":{},\"tags\":{s},\"rating\":{{\"score\":{d},\"count\":{d}}},\"total\":{d}}}", .{
            item.id, item.name, item.category, item.price, item.quantity, item.active, item.tags_text, item.rating.score, item.rating.count, total,
        }) catch return jsonError();
        off += entry.len;
    }

    const tail = std.fmt.bufPrint(buf[off..], "]}}", .{}) catch return jsonError();
    off += tail.len;

    return finishJson(ctx, buf[0..off]);
}

// json-comp profile: gzip the JSON body when the client offers gzip. The
// single-threaded event loop per worker (fork model) makes a process-global
// scratch buffer safe — each forked process has its own copy.
var gzip_out: [65536]u8 = undefined;
var json_buf: [65536]u8 = undefined;

fn finishJson(ctx: *router.HandlerContext, body: []const u8) response_mod.Response {
    if (ctx.request.getHeader("accept-encoding")) |ae| {
        if (std.mem.indexOf(u8, ae, "gzip") != null) {
            if (swerver.compress.gzipCompress(body, &gzip_out)) |clen| {
                return .{
                    .status = 200,
                    .headers = &[_]response_mod.Header{
                        .{ .name = "Content-Type", .value = "application/json" },
                        .{ .name = "Content-Encoding", .value = "gzip" },
                    },
                    .body = .{ .bytes = gzip_out[0..clen] },
                };
            }
        }
    }
    return .{
        .status = 200,
        .headers = &[_]response_mod.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .body = .{ .bytes = body },
    };
}

fn jsonError() response_mod.Response {
    return .{
        .status = 500,
        .headers = &[_]response_mod.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .body = .{ .bytes = "{\"error\":\"render failed\"}" },
    };
}

// ── Main ─────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try parseArgs(init.minimal.args, allocator);

    var loaded_config: ?swerver.config_file.LoadedConfig = null;
    defer if (loaded_config) |*lc| lc.deinit();

    var cfg: swerver.config.ServerConfig = blk: {
        if (args.config_path) |path| {
            loaded_config = swerver.config_file.loadConfigFile(allocator, path) catch |err| {
                std.log.err("failed to load config: {}", .{err});
                return err;
            };
            break :blk loaded_config.?.server_config;
        }
        break :blk swerver.config.ServerConfig.default();
    };

    if (args.cert_path) |c| cfg.tls.cert_path = c;
    if (args.key_path) |k| cfg.tls.key_path = k;
    try cfg.validate();

    loadDataset();

    var app_router = router.Router.init(.{});
    try app_router.get("/health", handleHealth);
    try app_router.get("/echo", handleEchoGet);
    try app_router.post("/echo", handleEchoPost);
    try app_router.get("/plaintext", handlePlaintext);
    try app_router.get("/pipeline", handlePipeline);
    try app_router.get("/baseline11", handleBaseline);
    try app_router.post("/baseline11", handleBaseline);
    try app_router.get("/baseline2", handleBaseline);
    try app_router.post("/baseline2", handleBaseline);
    try app_router.get("/json/:count", handleJson);
    try app_router.postDiscard("/upload", handleUpload);

    if (cfg.workers != 1) {
        var master = try swerver.Master.init(allocator, cfg, app_router, null);
        defer master.deinit();
        try master.run(null);
    } else {
        const srv = try swerver.ServerBuilder
            .config(cfg)
            .router(app_router)
            .build(allocator);
        defer {
            srv.deinit();
            allocator.destroy(srv);
        }
        try srv.run(null);
    }
}

const Args = struct {
    config_path: ?[]const u8 = null,
    cert_path: ?[:0]const u8 = null,
    key_path: ?[:0]const u8 = null,
};

fn parseArgs(args: std.process.Args, allocator: std.mem.Allocator) !Args {
    var result: Args = .{};
    var it = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer it.deinit();
    _ = it.next();
    while (it.next()) |arg_z| {
        const arg = std.mem.sliceTo(arg_z, 0);
        if (std.mem.eql(u8, arg, "--config")) {
            const value = it.next() orelse return error.MissingValue;
            result.config_path = std.mem.sliceTo(value, 0);
        } else if (std.mem.startsWith(u8, arg, "--config=")) {
            result.config_path = arg["--config=".len..];
        } else if (std.mem.eql(u8, arg, "--cert")) {
            const value = it.next() orelse return error.MissingValue;
            result.cert_path = std.mem.sliceTo(value, 0);
        } else if (std.mem.startsWith(u8, arg, "--cert=")) {
            result.cert_path = @ptrCast(arg["--cert=".len..]);
        } else if (std.mem.eql(u8, arg, "--key")) {
            const value = it.next() orelse return error.MissingValue;
            result.key_path = std.mem.sliceTo(value, 0);
        } else if (std.mem.startsWith(u8, arg, "--key=")) {
            result.key_path = @ptrCast(arg["--key=".len..]);
        }
    }
    return result;
}
