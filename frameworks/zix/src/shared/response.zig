//! Shared error responders (400/404/500/503) for the handlers.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

pub fn badRequest(fd: std.posix.fd_t) void {
    zix.Http1.sendSimpleFD(fd, 400, "text/plain", "Bad Request") catch {};
}

pub fn notFound(fd: std.posix.fd_t) void {
    zix.Http1.sendSimpleFD(fd, 404, "text/plain", "Not Found") catch {};
}

pub fn internalServerError(fd: std.posix.fd_t) void {
    zix.Http1.sendSimpleFD(fd, 500, "text/plain", "Internal Server Error") catch {};
}

pub fn serviceUnavailable(fd: std.posix.fd_t) void {
    zix.Http1.sendSimpleFD(fd, 503, "text/plain", "Service Unavailable") catch {};
}
