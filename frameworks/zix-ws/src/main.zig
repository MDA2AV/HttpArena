//! zix-ws
//!
//! zix.Http1 WebSocket (.URING), Router-only: one handler module per route
//! (src/handlers/). GET /ws upgrades, then the engine drives the echo loop:
//! frames are echoed on readiness and a pipelined burst is coalesced into one
//! write.

const std = @import("std");
const zix = @import("zix");

const ws = @import("handlers/ws.zig");

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = ws.PATH, .handler = ws.RESPONSE },
});

pub fn main(process: std.process.Init) !void {
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
        //
        .send_date_header = false,
        .max_response_headers = .{ .CUSTOM = 8 },
        //
        .kernel_backlog = 16 * 1024,
        .max_recv_buf = 6 * 1024,
        .ws_recv_buf = 32 * 1024,
        //
        .uring_send_buf_size = 16 * 1024,
        .uring_idle_pool_floor = 16,
        .uring_idle_pool_ceiling = 1 * 1024,
        .process_queue_len = park_len,
    });
    defer server.deinit();

    try server.run();
}
