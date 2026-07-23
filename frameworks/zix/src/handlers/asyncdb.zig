//! GET /async-db?min=..&max=..&limit=.. : price-range item scan. Queues a
//! Job on the worker's postgres lane (dbpg.zig), answered async.

const std = @import("std");
const zix = @import("zix");

const dbpg = @import("../shared/dbpg.zig");
const response = @import("../shared/response.zig");

// --------------------------------------------------------- //

pub const PATH = "/async-db";

const ASYNC_DB_LIMIT_MAX: i64 = 50;

// --------------------------------------------------------- //

pub fn RESPONSE(req: *zix.Http1.Request, _: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    const head = req.head;
    const fd = req.fd;

    const min: i64 = if (zix.Http1.queryParam(head, "min")) |raw| std.fmt.parseInt(i64, raw, 10) catch 0 else 0;
    const max: i64 = if (zix.Http1.queryParam(head, "max")) |raw| std.fmt.parseInt(i64, raw, 10) catch 0 else 0;
    var limit: i64 = if (zix.Http1.queryParam(head, "limit")) |raw| std.fmt.parseInt(i64, raw, 10) catch 10 else 10;
    if (limit < 1) limit = 1;
    if (limit > ASYNC_DB_LIMIT_MAX) limit = ASYNC_DB_LIMIT_MAX;

    const queued = dbpg.submitJob(head, .{ .ASYNC_DB = .{
        .fd = fd,
        .min = min,
        .max = max,
        .limit = limit,
    } });
    if (!queued) response.serviceUnavailable(fd);
}
