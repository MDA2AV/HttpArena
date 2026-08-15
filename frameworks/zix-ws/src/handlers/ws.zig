//! GET /ws : upgrade the connection, then hand it to the engine's echo loop.
//!
//! Note:
//! - Nothing is cached. Echo is per connection, so there is nothing to share
//!   between them.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

pub const PATH = "/ws";

// --------------------------------------------------------- //

/// Echo one text or binary frame back to its sender.
///
/// Note:
/// - Ping and close are answered by the engine before this runs.
/// - The frame callback returns void, so a failed echo has nowhere to report:
///   the handler has long returned by the time frames arrive. A broken send
///   here means the peer is gone, which the frame loop detects on its own read.
fn onFrame(fd: std.posix.fd_t, opcode: u8, payload: []const u8) void {
    zix.Http1.WebSocket.sendFD(fd, @enumFromInt(opcode), payload) catch {};
}

// --------------------------------------------------------- //

pub fn RESPONSE(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    const upgrade = req.header("upgrade") orelse "";
    const key = req.header("sec-websocket-key");

    if (!std.ascii.eqlIgnoreCase(upgrade, "websocket") or key == null) {
        res.setStatus(.BAD_REQUEST);

        try res.send("not a websocket upgrade request");
        return;
    }

    // Reported rather than answered here: the upgrade writes the 101 itself, so
    // a failure partway through has already put bytes on the wire and an HTTP
    // body sent after it would corrupt the stream. The engine sends its 500
    // only while nothing has been written.
    try zix.Http1.WebSocket.serve(req.fd, key.?, onFrame);
}
