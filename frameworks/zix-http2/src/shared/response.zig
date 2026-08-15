//! Shared error responders for the handlers: 400, 404, and 503.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

pub fn badRequest(fd: std.posix.fd_t, sid: u31) void {
    zix.Http2.sendResponseFD(fd, sid, 400, "text/plain", "Bad Request") catch {};
}

pub fn notFound(fd: std.posix.fd_t, sid: u31) void {
    zix.Http2.sendResponseFD(fd, sid, 404, "text/plain", "Not Found") catch {};
}

pub fn serviceUnavailable(fd: std.posix.fd_t, sid: u31) void {
    zix.Http2.sendResponseFD(fd, sid, 503, "text/plain", "Service Unavailable") catch {};
}
