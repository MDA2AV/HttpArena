//! HttpArena: zix
//!
//! zix.Http1 (.URING), Router-only: every request goes through the engine's
//! parser and the comptime Router, one handler module per route
//! (src/handlers/). TLS rides tls_port (dual listener, one worker fleet).
//! async-db and crud run over the driver-owned multiplexed transport
//! (dbpg.zig, sharded), crud reads also check the in-process cache
//! (crudcache.zig) mirrored to Redis (dbrd.zig).

const std = @import("std");
const zix = @import("zix");

const baseline = @import("handlers/baseline.zig");
const pipeline = @import("handlers/pipeline.zig");
const upload = @import("handlers/upload.zig");
const static = @import("handlers/static.zig");
const json = @import("handlers/json.zig");
const asyncdb = @import("handlers/asyncdb.zig");
const crud = @import("handlers/crud.zig");

const cache = @import("shared/cache.zig");
const dbpg = @import("shared/dbpg.zig");
const dbrd = @import("shared/dbrd.zig");

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = baseline.PATH, .handler = baseline.RESPONSE },
    .{ .path = pipeline.PATH, .handler = pipeline.RESPONSE },
    .{ .path = upload.PATH, .handler = upload.RESPONSE },
    .{ .path = asyncdb.PATH, .handler = asyncdb.RESPONSE },
    .{ .path = static.PATH, .handler = static.RESPONSE, .kind = .PREFIX },
    .{ .path = json.PATH, .handler = json.RESPONSE, .kind = .PREFIX },
    .{ .path = crud.PATH, .handler = crud.RESPONSE, .kind = .PREFIX },
});

pub fn main(process: std.process.Init) !void {
    var json_alloc = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer json_alloc.deinit();

    var tls_alloc = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer tls_alloc.deinit();

    try json.init(json_alloc.allocator());

    // DB endpoints: each driver's transport threads spawn only when its URL
    // is present (non-DB profiles run zero extra threads, DB routes answer
    // 503). Redis starts first, the postgrez shard threads mirror to it.
    dbpg.init(process);
    dbrd.init(process);
    dbrd.start();
    dbpg.start();

    var tls = zix.Tls.Context.init(tls_alloc.allocator(), process.io, .{
        .cert_path = "/etc/zix-tls/server.cert",
        .key_path = "/etc/zix-tls/server.key",
        .alpn = &.{.HTTP_1_1},
        .min_version = .TLS_1_3,
    }) catch |e| {
        return e;
    };

    // Park ring sized to peak conns per worker: 16384c is the deepest
    // scenario and workers = 0 spawns one worker per CPU.
    const cpus = std.Thread.getCpuCount() catch 8;
    const park_len = @max(512, 16 * 1024 / cpus);

    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = process.io,
        .ip = "::",
        .port = 8080,
        .workers = 0,
        .dispatch_model = .URING,
        .tls = &tls,
        .tls_port = 8081,
        //
        .send_date_header = false,
        .max_response_headers = .{ .CUSTOM = 8 },
        //
        .compress = true,
        //
        .response_cache = true,
        .cache_max_entries = 1 * 1024 / 2,
        .cache_max_value_bytes = 32 * 1024,
        .cache_ttl_ms = cache.TTL_MS,
        //
        .kernel_backlog = 16 * 1024,
        .max_recv_buf = 8 * 1024,
        //
        .uring_send_buf_size = 16 * 1024,
        .uring_idle_pool_floor = 16, // 0:256 1:16
        .uring_idle_pool_ceiling = 1 * 1024,
        .process_queue_len = park_len, // 0:8192 1:16384 / workers, floor 512
    });
    defer server.deinit();

    try server.run();
}
