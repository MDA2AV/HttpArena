//! GET/POST /baseline11?a=..&b=.. : sum the query values, plus the POST body
//! read as an integer. Answers the sum as text/plain.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

pub const PATH = "/baseline11";

/// Longest decimal the sum can print, sign included.
const SUM_BUF: usize = 32;

// --------------------------------------------------------- //

fn sumQuery(query: []const u8) i64 {
    var sum: i64 = 0;

    var it = std.mem.tokenizeScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (std.mem.indexOfScalar(u8, pair, '=')) |equals| {
            sum += std.fmt.parseInt(i64, pair[equals + 1 ..], 10) catch 0;
        }
    }

    return sum;
}

/// Read a leading integer out of `text`, skipping surrounding whitespace and
/// stopping at the first non-digit. A body with no digits reads as 0.
///
/// Note:
/// - Deliberately lenient: a chunked body arrives with framing bytes around
///   the number, and this profile is about the sum, not about rejecting input.
fn parseIntLoose(text: []const u8) i64 {
    var index: usize = 0;
    while (index < text.len and (text[index] == ' ' or text[index] == '\t' or text[index] == '\r' or text[index] == '\n')) index += 1;

    var negative = false;
    if (index < text.len and text[index] == '-') {
        negative = true;
        index += 1;
    }

    var value: i64 = 0;
    while (index < text.len and text[index] >= '0' and text[index] <= '9') : (index += 1) {
        value = value * 10 + (text[index] - '0');
    }

    return if (negative) -value else value;
}

// --------------------------------------------------------- //

pub fn RESPONSE(req: *zix.Http1.Request, _: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    const head = req.head;
    const body = try req.body();
    const fd = req.fd;

    var sum: i64 = sumQuery(head.query);
    if (req.method() == .POST and body.len > 0) {
        sum += parseIntLoose(body);
    }

    var body_buf: [SUM_BUF]u8 = undefined;
    const out = try std.fmt.bufPrint(&body_buf, "{d}", .{sum});

    try zix.Http1.sendSimpleFD(fd, 200, "text/plain", out);
}
