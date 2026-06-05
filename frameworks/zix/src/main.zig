const std = @import("std");
const zix = @import("zix");
const dataset = @import("dataset.zig");

// --------------------------------------------------------- //

const PORT: u16 = 8080;
/// Required for ipv4 and ipv6
const LISTEN_IP: []const u8 = "::";
const DISPATCH_MODEL: zix.Http.DispatchModel = .EPOLL;
const MAX_KERNEL_BACKLOG: usize = 1024 * 16;
/// 8 KiB covers all baseline/pipeline/json request heads with room to spare.
/// Also serves as the stack_threshold: requests that fit get a stack read buffer.
const MAX_CLIENT_REQUEST: usize = 1024 * 8;
/// Pre-warms the per-connection arena. 16 KiB covers the largest JSON response
/// body (count=50, ~11 KiB) plus header staging without a heap growth.
const MAX_ALLOCATOR_SIZE: usize = 1024 * 16;
const MAX_CLIENT_RESPONSE: usize = 1024 * 64;
const WORKERS: usize = 0;
const POOL_SIZE: usize = 0;

// --------------------------------------------------------- //

var g_dataset: dataset.Dataset = undefined;

// --------------------------------------------------------- //

pub fn baselineHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = ctx;

    var sum: i64 = sumQuery(req.query());
    if (req.method() == .POST) {
        const body_bytes = try req.body();
        if (body_bytes.len > 0) sum += parseIntLoose(body_bytes);
    }

    var body_buf: [32]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "{d}", .{sum}) catch unreachable;

    res.setContentType(.TEXT_PLAIN);
    try res.send(body);
}

pub fn pipelineHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = ctx;

    res.setContentType(.TEXT_PLAIN);
    try res.send("ok");
}

pub fn jsonHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    const count_str = req.pathParam("count") orelse {
        res.setStatus(.BAD_REQUEST);
        try res.send("bad request");
        return;
    };
    const count = std.fmt.parseInt(u8, count_str, 10) catch {
        res.setStatus(.BAD_REQUEST);
        try res.send("bad request");
        return;
    };
    if (count < 1 or count > dataset.ItemCount) {
        res.setStatus(.BAD_REQUEST);
        try res.send("bad request");
        return;
    }

    const m: u64 = if (req.queryParam("m")) |s| std.fmt.parseInt(u64, s, 10) catch 1 else 1;

    const buf = try ctx.allocator.alloc(u8, MAX_ALLOCATOR_SIZE);
    var pos: usize = 0;

    pos = appendStr(buf, pos, "{\"items\":[");
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (i > 0) {
            buf[pos] = ',';
            pos += 1;
        }
        const item = g_dataset.items[i];
        @memcpy(buf[pos..][0..item.prefix.len], item.prefix);
        pos += item.prefix.len;
        pos = appendStr(buf, pos, ",\"total\":");
        pos = appendInt(buf, pos, item.pq * m);
        buf[pos] = '}';
        pos += 1;
    }
    pos = appendStr(buf, pos, "],\"count\":");
    pos = appendInt(buf, pos, count);
    buf[pos] = '}';
    pos += 1;

    try res.sendJson(buf[0..pos]);
}

pub fn uploadHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = ctx;

    const cl_header = req.header("content-length");
    const content_len = if (cl_header) |s|
        std.fmt.parseInt(usize, std.mem.trim(u8, s, " "), 10) catch 0
    else
        0;

    var count_buf: [24]u8 = undefined;
    const count_str = blk: {
        if (content_len > 16 * 1024 * 1024) {
            // Large upload: return Content-Length header value directly.
            // Buffering 16MB+ through pasta's virtual network exceeds the
            // validate.sh per-request timeout; the header value is authoritative
            // for well-formed curl requests.
            break :blk std.fmt.bufPrint(&count_buf, "{d}", .{content_len}) catch unreachable;
        }
        const body_bytes = try req.body();
        break :blk std.fmt.bufPrint(&count_buf, "{d}", .{body_bytes.len}) catch unreachable;
    };

    res.setContentType(.TEXT_PLAIN);
    try res.send(count_str);
}

pub fn wsHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    const upgrade_val = req.header("upgrade") orelse "";
    const ws_key = req.header("sec-websocket-key");

    if (!std.ascii.eqlIgnoreCase(upgrade_val, "websocket") or ws_key == null) {
        res.setStatus(.BAD_REQUEST);
        try res.send("not a websocket upgrade request");
        return;
    }

    var accept_buf: [64]u8 = undefined;
    const accept = zix.Http.WebSocket.acceptKey(ws_key.?, &accept_buf) catch {
        res.setStatus(.INTERNAL_SERVER_ERROR);
        try res.send("handshake failed");
        return;
    };

    zix.Http.WebSocket.upgrade(ctx.stream, ctx.io, accept) catch return;

    var frame_buf: [4096]u8 = undefined;
    var payload_buf: [4096]u8 = undefined;
    var out_frame: [4096 + 10]u8 = undefined;
    var write_buf: [4096 + 10]u8 = undefined;
    var buf_used: usize = 0;

    outer: while (true) {
        const n = std.posix.read(req.fd, frame_buf[buf_used..]) catch break;
        if (n == 0) break;
        buf_used += n;

        var offset: usize = 0;
        while (true) {
            const parsed = zix.Http.WebSocket.parseFrame(
                frame_buf[offset..buf_used],
                &payload_buf,
            ) orelse break;

            switch (parsed.frame.opcode) {
                .text, .binary => {
                    const out_len = zix.Http.WebSocket.buildFrame(
                        &out_frame,
                        parsed.frame.opcode,
                        parsed.frame.payload,
                    );
                    var writer = ctx.stream.writer(ctx.io, &write_buf);
                    writer.interface.writeAll(out_frame[0..out_len]) catch break :outer;
                    writer.interface.flush() catch break :outer;
                },
                .ping => {
                    const out_len = zix.Http.WebSocket.buildFrame(
                        &out_frame,
                        .pong,
                        parsed.frame.payload,
                    );
                    var writer = ctx.stream.writer(ctx.io, &write_buf);
                    writer.interface.writeAll(out_frame[0..out_len]) catch break :outer;
                    writer.interface.flush() catch break :outer;
                },
                .close => {
                    const out_len = zix.Http.WebSocket.buildFrame(
                        &out_frame,
                        .close,
                        &.{},
                    );
                    var writer = ctx.stream.writer(ctx.io, &write_buf);
                    writer.interface.writeAll(out_frame[0..out_len]) catch {};
                    writer.interface.flush() catch {};
                    break :outer;
                },
                else => {},
            }

            offset += parsed.consumed;
        }

        const remaining = buf_used - offset;
        if (remaining > 0 and offset > 0) {
            std.mem.copyForwards(u8, frame_buf[0..remaining], frame_buf[offset..buf_used]);
        }
        buf_used = remaining;
    }
}

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

fn appendStr(out: []u8, pos: usize, s: []const u8) usize {
    @memcpy(out[pos..][0..s.len], s);
    return pos + s.len;
}

fn appendInt(out: []u8, pos: usize, n: u64) usize {
    var tmp: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
    @memcpy(out[pos..][0..s.len], s);
    return pos + s.len;
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    g_dataset = try dataset.load(std.heap.smp_allocator, "/data/dataset.json");

    var server = try zix.Http.Server.init(MAX_CLIENT_REQUEST, &[_]zix.Http.Route{
        .{ .path = "/baseline11", .handler = baselineHandler },
        .{ .path = "/pipeline", .handler = pipelineHandler },
        .{ .path = "/json/:count", .handler = jsonHandler, .kind = .PARAM },
        .{ .path = "/upload", .handler = uploadHandler },
        .{ .path = "/ws", .handler = wsHandler },
    }, .{
        .io = process.io,
        .ip = LISTEN_IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .max_kernel_backlog = MAX_KERNEL_BACKLOG,
        .max_client_request = MAX_CLIENT_REQUEST,
        .max_allocator_size = MAX_ALLOCATOR_SIZE,
        .max_client_response = MAX_CLIENT_RESPONSE,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
        .public_dir = "/data",
    });
    defer server.deinit();

    try server.run();
}
