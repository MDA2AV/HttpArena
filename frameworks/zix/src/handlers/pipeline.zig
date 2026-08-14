//! GET /pipeline : one fixed tiny response.
//!
//! Note:
//! - writeAllFD appends to the engine's staged sink, so a pipelined batch
//!   leaves in request order as a single send. The constant below is the whole
//!   response, not a memoized one: this route has no inputs, so there is
//!   nothing per request to compute or to cache.

const zix = @import("zix");

// --------------------------------------------------------- //

pub const PATH = "/pipeline";

const PIPELINE_RESPONSE: []const u8 =
    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nok";

// --------------------------------------------------------- //

pub fn RESPONSE(req: *zix.Http1.Request, _: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    const fd = req.fd;

    try zix.Http1.writeAllFD(fd, PIPELINE_RESPONSE);
}
