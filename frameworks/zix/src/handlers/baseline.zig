//! GET/POST /baseline11?a=..&b=.. : sum the query values, plus the POST body
//! as an integer. Returns the sum as text/plain.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

pub const PATH = "/baseline11";

// --------------------------------------------------------- //

fn sumQuery(query: []const u8) i64 {
    var sum: i64 = 0;
    var it = std.mem.tokenizeScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
            sum += std.fmt.parseInt(i64, pair[eq + 1 ..], 10) catch 0;
        }
    }
    return sum;
}

fn parseIntLoose(s: []const u8) i64 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\r' or s[i] == '\n')) i += 1;

    var neg = false;
    if (i < s.len and s[i] == '-') {
        neg = true;
        i += 1;
    }

    var n: i64 = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        n = n * 10 + (s[i] - '0');
    }

    return if (neg) -n else n;
}

// --------------------------------------------------------- //

pub fn RESPONSE(
    req: *zix.Http1.Request,
    _: *zix.Http1.Response,
    _: *zix.Http1.Context
) !void {
    const head = req.head;
    const body = try req.body();
    const fd = req.fd;

    var sum: i64 = sumQuery(head.query);

    if (req.method() == .POST and body.len > 0) {
    // if (std.mem.eql(u8, head.method, "POST") and body.len > 0) {
        sum += parseIntLoose(body);
    }

    var body_buf: [32]u8 = undefined;
    const out = std.fmt.bufPrint(&body_buf, "{d}", .{sum}) catch return;

    zix.Http1.sendSimpleFD(fd, 200, "text/plain", out) catch {
        try zix.Http1.sendSimpleFD(
            fd,
            @intFromEnum(zix.Http1.Status.Code.INTERNAL_SERVER_ERROR),
            zix.Http1.Content.Type.TEXT_PLAIN.asString(),
            zix.Http1.Status.Code.INTERNAL_SERVER_ERROR.asString()
        );
    };
}
