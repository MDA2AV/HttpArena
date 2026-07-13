//! HttpArena: zix
//!
//! Router-only variant: Server.init, no raw-byte interceptor. Every request,
//! /pipeline included, goes through the engine's parser and the comptime
//! Router. Pipelined correctness comes from the engine's staged response
//! sink: each handler write appends to the per-connection send buffer in
//! request order and the batch flushes as one on-ring send, so responses
//! coalesce without hand-rolled request-line scanning.
//!
//! Knobs carry the attempt-2b sweep result: busy-poll 16 us, warm idle pool
//! 256 floor / 1024 ceiling, 8 KiB recv buffer (deep pipelined batches parse
//! from one fill), 16 KiB send buffer.
//!
//! zix.Http1 (.URING) against the HttpArena HTTP/1.1 suite
//! (baseline, pipelined, limited-conn, json, json-comp, upload, static).
//! json-comp reuses /json and gzips on Accept-Encoding: gzip.
//! json-tls rides the same server through config.tls_port (dual listener):
//! cleartext on PORT plus https (TLS 1.3, baked Ed25519 cert) on TLS_PORT,
//! one worker fleet, one fd table, no second launch.

const std = @import("std");
const zix = @import("zix");

const dataset = @import("dataset.zig");
const handler = @import("handler.zig");

// --------------------------------------------------------- //

const IP: []const u8 = "::";
const PORT: u16 = 8080;
const DISPATCH_MODEL: zix.Http1.DispatchModel = .URING;

const MAX_HEADERS: u8 = 8;
const WORKERS: usize = 0;

const SEND_DATE_HEADER: bool = false;
const RESPONSE_CACHE: bool = true;
const CACHE_MAX_ENTRIES: u32 = 64;
const CACHE_MAX_VALUE_BYTES: u32 = 32 * 1024;

const TLS_PORT: u16 = 8081;
const TLS_CERT_DEFAULT: []const u8 = "/etc/zix-tls/server.crt";
const TLS_KEY_DEFAULT: []const u8 = "/etc/zix-tls/server.key";

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/baseline11", .handler = handler.baseline },
    .{ .path = "/pipeline", .handler = handler.pipeline },
    .{ .path = "/upload", .handler = handler.upload },
    .{ .path = "/json", .handler = handler.json, .kind = .PREFIX },
    .{ .path = "/static", .handler = handler.static, .kind = .PREFIX },
});

pub fn main(process: std.process.Init) !void {
    var allocator_dataset = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer allocator_dataset.deinit();

    var dataset_path_buf: [512]u8 = undefined;
    const data_dir = "/data";
    const dataset_path = try std.fmt.bufPrint(&dataset_path_buf, "{s}/dataset.json", .{data_dir});
    handler.g_dataset = try dataset.load(allocator_dataset.allocator(), dataset_path);
    handler.g_static_base = std.fmt.bufPrint(&handler.g_static_base_buf, "{s}/static/", .{data_dir}) catch "/data/static/";

    var allocator_tls = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer allocator_tls.deinit();

    var tls = zix.Tls.Context.init(allocator_tls.allocator(), process.io, .{
        .cert_path = TLS_CERT_DEFAULT,
        .key_path = TLS_KEY_DEFAULT,
        .alpn = &.{.HTTP_1_1},
        .min_version = .TLS_1_3,
    }) catch |e| {
        std.debug.print("Error tls context: {}\n", .{e});
        return;
    };
    defer tls.deinit();

    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .tls = &tls,
        .tls_port = TLS_PORT,
        .dispatch_model = DISPATCH_MODEL,
        .max_headers = MAX_HEADERS,
        .workers = WORKERS,
        .send_date_header = SEND_DATE_HEADER,
        .response_cache = RESPONSE_CACHE,
        .cache_max_entries = CACHE_MAX_ENTRIES,
        .cache_max_value_bytes = CACHE_MAX_VALUE_BYTES,
        .cache_ttl_ms = handler.CACHE_TTL_MS,
        .kernel_backlog = 16 * 1024,
        .max_recv_buf = 8 * 1024,
        .uring_send_buf_size = 16 * 1024,
        .uring_idle_pool_floor = 1 * 1024 / 4,
        .uring_idle_pool_ceiling = 1 * 1024,
        .process_queue_len = 2_000_000,
    });
    defer server.deinit();

    try server.run();
}
