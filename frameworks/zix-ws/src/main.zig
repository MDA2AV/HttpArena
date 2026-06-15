//! HttpArena: zix-ws
//! zix version: 0.4.x-rc2
//!
//! zix HttpArena WebSocket entry point.
//!
//! Intent: demonstrate the engine-owned WebSocket path of zix.Http1 (EPOLL
//! dispatch model) against the HttpArena echo and echo-pipeline suites.
//!
//! Design choices:
//! - GET /ws upgrades, then zix.Http1.WebSocket.serve drives the echo loop
//!   inside the engine: frames are echoed on readiness and a pipelined burst is
//!   coalesced into a single write.
//! - No response cache: echo is per-connection, not a broadcast fanout, so there
//!   is nothing to precompute or share across connections.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

const PORT: u16 = 8080;
const LISTEN_IP: []const u8 = "::";
const DISPATCH_MODEL: zix.Http1.DispatchModel = .EPOLL;
const KERNEL_BACKLOG: u31 = 16 * 1024;
const MAX_RECV_BUF: usize = 4 * 1024;
const WS_RECV_BUF: usize = 32 * 1024;
const MAX_HEADERS: u8 = 16;
const WORKERS: usize = 0;

// --------------------------------------------------------- //

fn badRequest(fd: std.posix.fd_t) void {
    zix.Http1.writeSimple(fd, 400, "text/plain", "bad request") catch {};
}

fn notFound(fd: std.posix.fd_t) void {
    zix.Http1.writeSimple(fd, 404, "text/plain", "Not Found") catch {};
}

// --------------------------------------------------------- //

// Echo every text/binary frame back. Ping/close are handled by the engine.
fn wsOnFrame(fd: std.posix.fd_t, opcode: u8, payload: []const u8) void {
    zix.Http1.WebSocket.send(fd, @enumFromInt(opcode), payload) catch {};
}

// GET /ws : WebSocket upgrade then engine-owned echo.
fn wsHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = body;

    const upgrade_val = zix.Http1.getHeader(head, "upgrade") orelse "";
    const ws_key = zix.Http1.getHeader(head, "sec-websocket-key");

    if (!std.ascii.eqlIgnoreCase(upgrade_val, "websocket") or ws_key == null) {
        return badRequest(fd);
    }

    zix.Http1.WebSocket.serve(fd, ws_key.?, wsOnFrame) catch {
        zix.Http1.writeSimple(fd, 500, "text/plain", "handshake failed") catch {};
        return;
    };
}

// --------------------------------------------------------- //

fn dispatch(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    if (std.mem.eql(u8, head.path, "/ws")) return wsHandler(head, body, fd);

    notFound(fd);
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    // Elevate scheduling priority (setpriority -19). Fails silently when the
    // process lacks CAP_SYS_NICE, so no special capability is required for correctness.
    _ = std.os.linux.syscall3(.setpriority, 0, 0, @as(usize, @bitCast(@as(isize, -19))));

    var server = zix.Http1.Server.init(dispatch, .{
        .io = process.io,
        .ip = LISTEN_IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
        .ws_recv_buf = WS_RECV_BUF,
        .max_headers = MAX_HEADERS,
        .workers = WORKERS,
        .send_date_header = false,
    });
    defer server.deinit();

    try server.run();
}
