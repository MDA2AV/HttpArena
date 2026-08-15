//! GET/POST /baseline2?a=..&b=.. : sum the query values, plus the POST body
//! read as an integer. Answers the sum as text/plain.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

pub const PATH = "/baseline2";

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

pub fn RESPONSE(req: *zix.Http2.Request, res: *zix.Http2.Response, _: *zix.Http2.Context) !void {
    var sum: i64 = sumQuery(req.query);
    if (std.mem.eql(u8, req.method, "POST") and req.body.len > 0) {
        sum += parseIntLoose(req.body);
    }

    var body_buf: [SUM_BUF]u8 = undefined;
    const out = std.fmt.bufPrint(&body_buf, "{d}", .{sum}) catch return;

    try res.sendText(out);
}
