//! GET /pipeline : fixed tiny response. writeAllFD appends to the engine's
//! staged sink, a pipelined batch leaves in request order as one send.

const zix = @import("zix");

// --------------------------------------------------------- //

pub const PATH = "/pipeline";

const PIPELINE_RESP: []const u8 =
    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nok";

// --------------------------------------------------------- //

pub fn RESPONSE(req: *zix.Http1.Request, _: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    const fd = req.fd;

    zix.Http1.writeAllFD(req.fd, PIPELINE_RESP) catch {
        try zix.Http1.sendSimpleFD(fd, @intFromEnum(zix.Http1.Status.Code.INTERNAL_SERVER_ERROR), zix.Http1.Content.Type.TEXT_PLAIN.asString(), zix.Http1.Status.Code.INTERNAL_SERVER_ERROR.asString());
    };
}
