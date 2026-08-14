//! POST /upload : ingest the request body and answer how many bytes came off
//! the socket.
//!
//! Note:
//! - The count is req.bodyReceived(), which the engine tallies from the reads
//!   that received the bytes. The Content-Length header value is never used,
//!   so a lying header cannot inflate the answer.
//! - The delivered bytes are copied into this worker's sink before the count
//!   is reported, so the server really does take the upload into its own
//!   memory rather than only counting it going past.
//! - Bytes beyond the connection receive buffer are drained and counted by the
//!   engine itself. zix.Http1 exposes no streaming body sink, so a handler
//!   cannot hold those without a receive buffer as large as the largest
//!   upload, which at this profile's connection counts would cost more memory
//!   than the whole rest of the entry. The limit is the engine's, and it is
//!   recorded in the entry README rather than papered over here.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

pub const PATH = "/upload";

/// Per-worker ingest sink. Holds the delivered prefix of one body at a time,
/// which is all a worker ever has in hand at once.
const SINK_BYTES: usize = 1024 * 1024;

threadlocal var tl_sink: [SINK_BYTES]u8 = undefined;

/// Longest decimal the byte count can print.
const COUNT_BUF: usize = 24;

// --------------------------------------------------------- //

pub fn RESPONSE(req: *zix.Http1.Request, _: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    const fd = req.fd;
    const body = try req.body();

    const taken = @min(body.len, SINK_BYTES);
    @memcpy(tl_sink[0..taken], body[0..taken]);

    const received: u64 = req.bodyReceived();

    var body_buf: [COUNT_BUF]u8 = undefined;
    const out = try std.fmt.bufPrint(&body_buf, "{d}", .{received});

    try zix.Http1.sendSimpleFD(fd, @intFromEnum(zix.Http1.Status.Code.OK), zix.Http1.Content.Type.TEXT_PLAIN.asString(), out);
}
