//! GET /json/{count}?m=M : render count dataset items, total = price*qty*m.
//! The body is deterministic in (count, m), cached by key: identity via the
//! engine's response cache, gzip via the per-(key, encoding) cache.

const std = @import("std");
const zix = @import("zix");

const response = @import("../shared/response.zig");
const dataset = @import("../shared/dataset.zig");
const util = @import("../shared/util.zig");
const cache = @import("../shared/cache.zig");

// --------------------------------------------------------- //

pub const PATH = "/json";

/// Must initialize in main (the loaded dataset the bodies render from).
pub var g_dataset: dataset.Dataset = undefined;

// Reserve for the identity JSON header, rendered right-aligned so it ends
// exactly where the body starts (reserve-prefix assembly, no body copy).
const JSON_HDR_RESERVE: usize = 96;
threadlocal var json_resp_buf: [JSON_HDR_RESERVE + 32 * 1024]u8 = undefined;

// --------------------------------------------------------- //

fn sendJsonGzipFD(head: *const zix.Http1.ParsedHead, fd: std.posix.fd_t, json_body: []const u8) void {
    zix.Http1.sendGzipCachedFD(fd, head, 200, "application/json", json_body, zix.Http1.cacheTtl()) catch {};
}

// --------------------------------------------------------- //

pub fn init(aa: std.mem.Allocator) !void {
    var dataset_path_buf: [512]u8 = undefined;
    const data_dir = "/data";
    const dataset_path =
        try std.fmt.bufPrint(&dataset_path_buf, "{s}/dataset.json", .{data_dir});
    g_dataset = try dataset.load(aa, dataset_path);
}

pub fn RESPONSE(
    req: *zix.Http1.Request,
    _: *zix.Http1.Response,
    _: *zix.Http1.Context
) !void {
    const head = req.head;
    const fd = req.fd;

    const accept = zix.Http1.acceptEncoding(head) orelse "";
    const want_gzip = std.mem.indexOf(u8, accept, "gzip") != null;

    if (want_gzip) {
        if (zix.Http1.cacheLookupEncoded(head, "gzip")) |cached| {
            zix.Http1.writeAllFD(fd, cached) catch {};
            return;
        }
    } else {
        if (zix.Http1.cacheLookup(head)) |cached| {
            zix.Http1.writeAllFD(fd, cached) catch {};
            return;
        }
    }

    // The PREFIX route also matches a bare /json (no trailing slash), which
    // would slice out of bounds below.
    if (head.path.len < "/json/".len) return response.badRequest(fd);

    const count_str = head.path["/json/".len..];
    const count =
        std.fmt.parseInt(u8, count_str, 10) catch return response.badRequest(fd);
    if (count < 1 or count > dataset.ItemCount) return response.badRequest(fd);

    const m: u64 =
        if (zix.Http1.queryParam(head, "m")) |s| std.fmt.parseInt(u64, s, 10) catch
            1 else 1;

    const buf = json_resp_buf[JSON_HDR_RESERVE..];
    var pos: usize = 0;

    pos = util.appendStr(buf, pos, "{\"items\":[");
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (i > 0) {
            buf[pos] = ',';
            pos += 1;
        }
        const item = g_dataset.items[i];
        @memcpy(buf[pos..][0..item.prefix.len], item.prefix);
        pos += item.prefix.len;
        pos = util.appendStr(buf, pos, ",\"total\":");
        pos = util.appendInt(buf, pos, item.pq * m);
        buf[pos] = '}';
        pos += 1;
    }
    pos = util.appendStr(buf, pos, "],\"count\":");
    pos = util.appendInt(buf, pos, count);
    buf[pos] = '}';
    pos += 1;

    if (want_gzip) {
        sendJsonGzipFD(head, fd, buf[0..pos]);
        return;
    }

    // The header renders right-aligned into the reserve so it ends exactly
    // where the body starts: the full response caches and replays verbatim
    // (the header matches the engine's sendJsonFD output) with no body copy.
    var hdr_buf: [JSON_HDR_RESERVE]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{pos}) catch {
        zix.Http1.sendJsonFD(fd, 200, buf[0..pos]) catch {};
        return;
    };
    const start = JSON_HDR_RESERVE - hdr.len;
    @memcpy(json_resp_buf[start..JSON_HDR_RESERVE], hdr);

    zix.Http1.sendWithCacheFD(fd, head, json_resp_buf[start .. JSON_HDR_RESERVE + pos], cache.TTL_MS) catch {
        try zix.Http1.sendSimpleFD(
            fd,
            @intFromEnum(zix.Http1.Status.Code.INTERNAL_SERVER_ERROR),
            zix.Http1.Content.Type.TEXT_PLAIN.asString(),
            zix.Http1.Status.Code.INTERNAL_SERVER_ERROR.asString()
        );
    };
}

