//! Accept-Encoding parsing shared by the static and json handlers: a
//! substring scan for br/gzip tokens, no q-value parsing.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

/// Accept-Encoding tokens the client advertised (substring scan, the bench
/// header needs no q-value parsing).
pub const AcceptEncoding = struct {
    prefers_br: bool,
    accepts_gzip: bool,
};

// --------------------------------------------------------- //

pub fn accept(head: *const zix.Http1.ParsedHead) AcceptEncoding {
    const value =
        zix.Http1.acceptEncoding(head) orelse
        return .{ .prefers_br = false, .accepts_gzip = false };

    return .{
        .prefers_br = std.mem.indexOf(u8, value, "br") != null,
        .accepts_gzip = std.mem.indexOf(u8, value, "gzip") != null,
    };
}
