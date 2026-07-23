//! POST /upload : return how many body bytes were read off the socket
//! (bodyReceived), not the Content-Length value.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

pub const PATH = "/upload";

// --------------------------------------------------------- //

pub fn RESPONSE(req: *zix.Http1.Request, _: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    const fd = req.fd;

    const n: u64 = req.bodyReceived();

    var body_buf: [24]u8 = undefined;
    const out = std.fmt.bufPrint(&body_buf, "{d}", .{n}) catch return;

    zix.Http1.sendSimpleFD(fd, @intFromEnum(zix.Http1.Status.Code.OK), zix.Http1.Content.Type.TEXT_PLAIN.asString(), out) catch {
        try zix.Http1.sendSimpleFD(fd, @intFromEnum(zix.Http1.Status.Code.INTERNAL_SERVER_ERROR), zix.Http1.Content.Type.TEXT_PLAIN.asString(), zix.Http1.Status.Code.INTERNAL_SERVER_ERROR.asString());
    };
}
