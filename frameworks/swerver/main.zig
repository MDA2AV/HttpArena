const std = @import("std");
const swerver = @import("swerver");

const router = swerver.router;
const response_mod = swerver.response;
const clock = swerver.runtime.clock;
const db_routes = @import("db_routes.zig");

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
    tags: []const []const u8,
    rating: Rating,
};

/// The /json response item: a dataset item plus the per-request computed
/// `total`. Handed to std.json for serialization — no hand-formatting.
const JsonItem = struct {
    id: i64,
    name: []const u8,
    category: []const u8,
    price: i64,
    quantity: i64,
    active: bool,
    tags: []const []const u8,
    rating: Rating,
    total: i64,
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

        // Copy each tag string into the byte pool and collect the slices so
        // the item holds a real []const []const u8 that std.json can encode.
        const tags_start = tag_slice_off;
        for (item.tags) |tag| {
            const s = tags_pool_off;
            @memcpy(tags_pool[s .. s + tag.len], tag);
            tags_pool_off += tag.len;
            tag_slices[tag_slice_off] = tags_pool[s .. s + tag.len];
            tag_slice_off += 1;
        }

        dataset_items[i] = .{
            .id = item.id,
            .name = name_pool[ns .. ns + item.name.len],
            .category = cat_pool[cs .. cs + item.category.len],
            .price = item.price,
            .quantity = item.quantity,
            .active = item.active,
            .tags = tag_slices[tags_start..tag_slice_off],
            .rating = item.rating,
        };
    }
    dataset_len = count;
}

// Flat pools for dataset strings (outlive the parse arena).
var name_pool: [1024]u8 = undefined;
var name_pool_off: usize = 0;
var cat_pool: [1024]u8 = undefined;
var cat_pool_off: usize = 0;
var tags_pool: [8192]u8 = undefined;
var tags_pool_off: usize = 0;
var tag_slices: [512][]const u8 = undefined;
var tag_slice_off: usize = 0;

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

// ── Unary gRPC ───────────────────────────────────────────────────

fn grpcError(status: []const u8) response_mod.Response {
    return .{
        .status = 200,
        .headers = &[_]response_mod.Header{
            .{ .name = "Content-Type", .value = "application/grpc" },
            .{ .name = "grpc-status", .value = status },
        },
        .body = .none,
    };
}

fn readProtoVarint(data: []const u8, offset: *usize) ?u64 {
    var value: u64 = 0;
    var shift: u6 = 0;
    var count: usize = 0;
    while (offset.* < data.len and count < 10) : (count += 1) {
        const byte = data[offset.*];
        offset.* += 1;
        value |= @as(u64, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return value;
        if (shift == 63) return null;
        shift += 7;
    }
    return null;
}

fn writeProtoVarint(dst: []u8, value_arg: u64) ?usize {
    var value = value_arg;
    var written: usize = 0;
    while (true) {
        if (written == dst.len) return null;
        var byte: u8 = @intCast(value & 0x7f);
        value >>= 7;
        if (value != 0) byte |= 0x80;
        dst[written] = byte;
        written += 1;
        if (value == 0) return written;
    }
}

/// POST /benchmark.BenchmarkService/GetSum — unary gRPC SumRequest → SumReply.
/// The benchmark schema is two int32 varints (`a` field 1, `b` field 2) and a
/// single int32 varint result. The gRPC envelope is the standard compression
/// flag plus a four-byte big-endian protobuf length.
fn handleGrpcSum(ctx: *router.HandlerContext) response_mod.Response {
    const request_body = ctx.request.body.sliceOrNull() orelse
        ctx.request.body.copyTo(ctx.response_buf) orelse return grpcError("8");
    if (request_body.len < 5 or request_body[0] != 0) return grpcError("3");

    const message_len = std.mem.readInt(u32, request_body[1..5], .big);
    if (message_len != request_body.len - 5) return grpcError("3");
    const message = request_body[5..];

    var a: u64 = 0;
    var b: u64 = 0;
    var offset: usize = 0;
    while (offset < message.len) {
        const tag = readProtoVarint(message, &offset) orelse return grpcError("3");
        if (tag & 0x7 != 0) return grpcError("3");
        const value = readProtoVarint(message, &offset) orelse return grpcError("3");
        switch (tag >> 3) {
            1 => a = value,
            2 => b = value,
            else => {},
        }
    }

    const out = ctx.response_buf;
    out[0] = 0;
    out[5] = 0x08; // SumReply.result, protobuf field 1 / wire type 0
    const value_len = writeProtoVarint(out[6..], a +% b) orelse return grpcError("13");
    const protobuf_len: u32 = @intCast(1 + value_len);
    std.mem.writeInt(u32, out[1..5], protobuf_len, .big);

    return .{
        .status = 200,
        .headers = &[_]response_mod.Header{
            .{ .name = "Content-Type", .value = "application/grpc" },
            .{ .name = "grpc-status", .value = "0" },
        },
        .body = .{ .bytes = out[0 .. 5 + protobuf_len] },
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

    // Assemble the payload as real structs and let std.json encode it — no
    // hand-formatting. `total` is the per-request price * quantity * m.
    var items: [MAX_ITEMS]JsonItem = undefined;
    for (dataset_items[0..count], 0..) |item, i| {
        items[i] = .{
            .id = item.id,
            .name = item.name,
            .category = item.category,
            .price = item.price,
            .quantity = item.quantity,
            .active = item.active,
            .tags = item.tags,
            .rating = item.rating,
            .total = item.price * item.quantity * m,
        };
    }

    const payload = .{ .count = count, .items = items[0..count] };

    // json-comp profile: gzip when the client offers it. Serialize once with
    // std.json into a process-global buffer (per-worker safe under the fork
    // model), then compress.
    if (ctx.request.getHeader("accept-encoding")) |ae| {
        if (std.mem.indexOf(u8, ae, "gzip") != null) {
            var w = std.Io.Writer.fixed(json_buf[0..]);
            std.json.Stringify.value(payload, .{}, &w) catch return jsonError();
            if (swerver.compress.gzipCompress(w.buffered(), &gzip_out)) |clen| {
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

    // Plain JSON: ctx.jsonValue serializes the struct — the idiomatic way to
    // return JSON from a swerver handler, no hand-formatting.
    return ctx.jsonValue(200, payload);
}

// Process-global scratch for the gzipped json-comp variant. Per-worker safe
// under the fork model — each forked process has its own copy.
var gzip_out: [65536]u8 = undefined;
var json_buf: [65536]u8 = undefined;

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
    try app_router.post("/benchmark.BenchmarkService/GetSum", handleGrpcSum);
    try db_routes.register(&app_router);

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
