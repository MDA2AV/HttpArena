//! Shared error responders for the handlers: 400, 404, and 503.
//!
//! Note:
//! - Each reports its send failure rather than swallowing it, so a caller
//!   writes `try response.badRequest(fd)` and the engine completes the request
//!   with its own default when the send could not be made.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

pub fn badRequest(fd: std.posix.fd_t) !void {
    try zix.Http1.sendSimpleFD(fd, 400, "text/plain", "Bad Request");
}

pub fn notFound(fd: std.posix.fd_t) !void {
    try zix.Http1.sendSimpleFD(fd, 404, "text/plain", "Not Found");
}

pub fn serviceUnavailable(fd: std.posix.fd_t) !void {
    try zix.Http1.sendSimpleFD(fd, 503, "text/plain", "Service Unavailable");
}
