//! GET /json/{count}?m=M : render count dataset items, total = price*qty*m.
//! Every response serializes per request from the loaded dataset, gzip
//! compresses per request when the client accepts it.

const std = @import("std");
const zix = @import("zix");

const response = @import("../shared/response.zig");
const dataset = @import("../shared/dataset.zig");
const util = @import("../shared/util.zig");

// --------------------------------------------------------- //

pub const PATH = "/json";

/// Must initialize in main (the loaded dataset the bodies render from).
pub var g_dataset: dataset.Dataset = undefined;

// Space in front of the body for the header, so header plus body go out as
// one slice.
const JSON_HDR_RESERVE: usize = 96;
threadlocal var json_resp_buf: [JSON_HDR_RESERVE + 32 * 1024]u8 = undefined;

// --------------------------------------------------------- //

fn sendJsonGzipFD(fd: std.posix.fd_t, json_body: []const u8) void {
    zix.Http1.sendGzipFD(fd, 200, "application/json", json_body) catch {};
}

// --------------------------------------------------------- //

/// Largest body one render can produce, measured at init. Sizes the reserve.
var g_body_max: usize = 0;

pub fn init(aa: std.mem.Allocator) !void {
    var dataset_path_buf: [512]u8 = undefined;
    const data_dir = "/data";
    const dataset_path =
        try std.fmt.bufPrint(&dataset_path_buf, "{s}/dataset.json", .{data_dir});
    g_dataset = try dataset.load(aa, dataset_path);

    const full = renderItems(json_resp_buf[JSON_HDR_RESERVE..], dataset.ItemCount, 1);
    g_body_max = full + (dataset.ItemCount + 1) * 20;
}

/// Render the items body for (count, m) into buf, returning the body length.
fn renderItems(buf: []u8, count: u8, m: u64) usize {
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

    return pos;
}

pub fn RESPONSE(req: *zix.Http1.Request, _: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    const head = req.head;
    const fd = req.fd;

    const accept = zix.Http1.acceptEncoding(head) orelse "";
    const want_gzip = std.mem.indexOf(u8, accept, "gzip") != null;

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

    // No-gzip path: render the body straight into the engine's send buffer,
    // the engine puts the header in front. The body is written once, no copy.
    if (!want_gzip) {
        if (zix.Http1.responseReserve(fd, g_body_max)) |region| {
            const body_len = renderItems(region, count, m);

            try zix.Http1.responseCommit(fd, 200, "application/json", body_len);
            return;
        }
    }

    const buf = json_resp_buf[JSON_HDR_RESERVE..];
    const pos = renderItems(buf, count, m);

    if (want_gzip) {
        sendJsonGzipFD(fd, buf[0..pos]);
        return;
    }

    // The header is built right before the body, so both go out as one slice.
    var hdr_buf: [JSON_HDR_RESERVE]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{pos}) catch {
        zix.Http1.sendJsonFD(fd, 200, buf[0..pos]) catch {};
        return;
    };
    const start = JSON_HDR_RESERVE - hdr.len;
    @memcpy(json_resp_buf[start..JSON_HDR_RESERVE], hdr);

    zix.Http1.writeAllFD(fd, json_resp_buf[start .. JSON_HDR_RESERVE + pos]) catch {
        try zix.Http1.sendSimpleFD(fd, @intFromEnum(zix.Http1.Status.Code.INTERNAL_SERVER_ERROR), zix.Http1.Content.Type.TEXT_PLAIN.asString(), zix.Http1.Status.Code.INTERNAL_SERVER_ERROR.asString());
    };
}
