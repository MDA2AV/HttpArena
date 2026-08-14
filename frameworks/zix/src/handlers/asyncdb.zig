//! GET /async-db?min=..&max=..&limit=.. : price-range item scan. Queues a Job
//! on this worker's postgres lane (dbpg.zig) and is answered from the reply.

const std = @import("std");
const zix = @import("zix");

const dbpg = @import("../shared/dbpg.zig");
const response = @import("../shared/response.zig");

// --------------------------------------------------------- //

pub const PATH = "/async-db";

/// Rows one scan may return. The profile's templates ask for 5 to 50.
const LIMIT_MAX: i64 = 50;
const LIMIT_DEFAULT: i64 = 10;

// --------------------------------------------------------- //

fn queryInt(head: *const zix.Http1.ParsedHead, name: []const u8, fallback: i64) i64 {
    const raw = zix.Http1.queryParam(head, name) orelse return fallback;

    return std.fmt.parseInt(i64, raw, 10) catch fallback;
}

// --------------------------------------------------------- //

pub fn RESPONSE(req: *zix.Http1.Request, _: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    const head = req.head;
    const fd = req.fd;

    const min = queryInt(head, "min", 0);
    const max = queryInt(head, "max", 0);
    const limit = std.math.clamp(queryInt(head, "limit", LIMIT_DEFAULT), 1, LIMIT_MAX);

    const queued = dbpg.submitJob(head, .{ .ASYNC_DB = .{
        .fd = fd,
        .min = min,
        .max = max,
        .limit = limit,
    } });

    if (!queued) try response.serviceUnavailable(fd);
}
