//! zix-http2
//!
//! zix.Http2 (.URING), Router-only: every request goes through the engine's
//! frame path and the comptime Router, one handler module per route
//! (src/handlers/). One server, two listeners through tls_port: h2c on 8082
//! and h2 over TLS 1.3 (ALPN h2) on 8443, from the same worker fleet.
//! /static is served by the engine from public_dir.

const std = @import("std");
const zix = @import("zix");

const baseline = @import("handlers/baseline.zig");
const json = @import("handlers/json.zig");

const paths = @import("shared/paths.zig");

// --------------------------------------------------------- //

const Routes = zix.Http2.Router(&[_]zix.Http2.Route{
    .{ .path = baseline.PATH, .handler = baseline.RESPONSE },
    .{ .path = json.PATH, .handler = json.RESPONSE, .kind = .PREFIX },
});

pub fn main(process: std.process.Init) !void {
    var tls_alloc = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer tls_alloc.deinit();

    var tls = zix.Tls.Context.init(tls_alloc.allocator(), process.io, .{
        .cert_path = paths.TLS_CERT,
        .key_path = paths.TLS_KEY,
        .alpn = &.{.H2},
        .min_version = .TLS_1_3,
    }) catch |e| {
        return e;
    };

    var server = zix.Http2.Server.init(Routes.dispatch, .{
        .io = process.io,
        .ip = "::",
        .port = 8082,
        .workers = 0,
        .dispatch_model = .URING,
        .tls = &tls,
        .tls_port = 8443,
        //
        .public_dir = paths.DATA_DIR,
        .public_dir_cache_ttl_ms = 30 * 1000,
        //
        .kernel_backlog = 24 * 1024,
        .max_streams = 1024,
        .max_frame_size = 24 * 1024,
        .max_recv_buf = 64 * 1024,
        .max_body = 32 * 1024,
        .tls_write_buf_initial_bytes = 32 * 1024,
    });
    defer server.deinit();

    try server.run();
}
