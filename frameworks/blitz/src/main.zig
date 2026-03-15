const std = @import("std");
const mem = std.mem;
const blitz = @import("blitz.zig");

// ── Global pre-computed responses ───────────────────────────────────
var dataset_json_resp: []const u8 = "";

const StaticFile = struct {
    name: []const u8,
    response: []const u8,
};
var static_file_list: [64]StaticFile = undefined;
var static_file_count: usize = 0;

// ── Handlers ────────────────────────────────────────────────────────

fn handlePipeline(_: *blitz.Request, res: *blitz.Response) void {
    _ = res.rawResponse("HTTP/1.1 200 OK\r\nServer: blitz\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nok");
}

fn handleBaseline(req: *blitz.Request, res: *blitz.Response) void {
    var sum: i64 = 0;
    if (req.query) |q| sum = parseQuerySum(q);
    if (req.method == .POST) {
        if (req.body) |body| {
            const trimmed = mem.trim(u8, body, " \t\r\n");
            sum += std.fmt.parseInt(i64, trimmed, 10) catch 0;
        }
    }
    var nb: [32]u8 = undefined;
    _ = res.textBuf(blitz.writeI64(&nb, sum));
}

fn handleBaseline2(req: *blitz.Request, res: *blitz.Response) void {
    var sum: i64 = 0;
    if (req.query) |q| sum = parseQuerySum(q);
    var nb: [32]u8 = undefined;
    _ = res.textBuf(blitz.writeI64(&nb, sum));
}

fn handleJson(_: *blitz.Request, res: *blitz.Response) void {
    _ = res.rawResponse(dataset_json_resp);
}

fn handleUpload(req: *blitz.Request, res: *blitz.Response) void {
    if (req.body) |body| {
        var nb: [32]u8 = undefined;
        _ = res.textBuf(blitz.writeUsize(&nb, body.len));
    } else {
        _ = res.text("0");
    }
}

fn handleStatic(req: *blitz.Request, res: *blitz.Response) void {
    const filepath = req.params.get("filepath") orelse {
        _ = res.setStatus(.not_found).text("Not Found");
        return;
    };
    for (0..static_file_count) |i| {
        if (mem.eql(u8, static_file_list[i].name, filepath)) {
            _ = res.rawResponse(static_file_list[i].response);
            return;
        }
    }
    _ = res.setStatus(.not_found).text("Not Found");
}

// ── Helpers ─────────────────────────────────────────────────────────

fn parseQuerySum(query: []const u8) i64 {
    var sum: i64 = 0;
    var it = mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (mem.indexOfScalar(u8, pair, '=')) |eq| {
            sum += std.fmt.parseInt(i64, pair[eq + 1 ..], 10) catch continue;
        }
    }
    return sum;
}

// ── Dataset loading ─────────────────────────────────────────────────

fn loadDataset(path: []const u8) []const u8 {
    const alloc = std.heap.c_allocator;
    const file = std.fs.openFileAbsolute(path, .{}) catch return "";
    defer file.close();
    const raw = file.readToEndAlloc(alloc, 64 * 1024 * 1024) catch return "";
    defer alloc.free(raw);

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch return "";
    const items = parsed.value.array.items;

    var out = std.ArrayList(u8).init(alloc);
    var json_buf = std.ArrayList(u8).init(alloc);
    json_buf.appendSlice("{\"items\":[") catch return "";

    for (items, 0..) |item, idx| {
        if (idx > 0) json_buf.append(',') catch {};
        const obj = item.object;
        const price = switch (obj.get("price").?) {
            .float => |f| f,
            .integer => |i| @as(f64, @floatFromInt(i)),
            else => 0.0,
        };
        const quantity = switch (obj.get("quantity").?) {
            .integer => |i| i,
            else => 0,
        };
        const total = @round(price * @as(f64, @floatFromInt(quantity)) * 100.0) / 100.0;

        json_buf.appendSlice("{\"id\":") catch {};
        writeJsonValue(&json_buf, obj.get("id").?);
        json_buf.appendSlice(",\"name\":") catch {};
        writeJsonValue(&json_buf, obj.get("name").?);
        json_buf.appendSlice(",\"category\":") catch {};
        writeJsonValue(&json_buf, obj.get("category").?);
        json_buf.appendSlice(",\"price\":") catch {};
        writeJsonValue(&json_buf, obj.get("price").?);
        json_buf.appendSlice(",\"quantity\":") catch {};
        writeJsonValue(&json_buf, obj.get("quantity").?);
        json_buf.appendSlice(",\"active\":") catch {};
        writeJsonValue(&json_buf, obj.get("active").?);
        json_buf.appendSlice(",\"tags\":") catch {};
        writeJsonValue(&json_buf, obj.get("tags").?);
        json_buf.appendSlice(",\"rating\":") catch {};
        writeJsonValue(&json_buf, obj.get("rating").?);
        json_buf.appendSlice(",\"total\":") catch {};
        writeFloat(&json_buf, total);
        json_buf.append('}') catch {};
    }

    var count_buf: [32]u8 = undefined;
    json_buf.appendSlice("],\"count\":") catch {};
    json_buf.appendSlice(blitz.writeUsize(&count_buf, items.len)) catch {};
    json_buf.append('}') catch {};

    var cl_buf: [32]u8 = undefined;
    out.appendSlice("HTTP/1.1 200 OK\r\nServer: blitz\r\nContent-Type: application/json\r\nContent-Length: ") catch return "";
    out.appendSlice(blitz.writeUsize(&cl_buf, json_buf.items.len)) catch return "";
    out.appendSlice("\r\n\r\n") catch return "";
    out.appendSlice(json_buf.items) catch return "";

    json_buf.deinit();
    return out.toOwnedSlice() catch "";
}

fn writeJsonValue(out: *std.ArrayList(u8), val: std.json.Value) void {
    switch (val) {
        .string => |s| {
            out.append('"') catch return;
            for (s) |ch| switch (ch) {
                '"' => out.appendSlice("\\\"") catch return,
                '\\' => out.appendSlice("\\\\") catch return,
                '\n' => out.appendSlice("\\n") catch return,
                '\r' => out.appendSlice("\\r") catch return,
                '\t' => out.appendSlice("\\t") catch return,
                else => out.append(ch) catch return,
            };
            out.append('"') catch return;
        },
        .integer => |i| {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch return;
            out.appendSlice(s) catch return;
        },
        .float => |f| writeFloat(out, f),
        .bool => |b| out.appendSlice(if (b) "true" else "false") catch return,
        .null => out.appendSlice("null") catch return,
        .array => |arr| {
            out.append('[') catch return;
            for (arr.items, 0..) |item, idx| {
                if (idx > 0) out.append(',') catch {};
                writeJsonValue(out, item);
            }
            out.append(']') catch return;
        },
        .object => |obj| {
            out.append('{') catch return;
            var first = true;
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (!first) out.append(',') catch {};
                first = false;
                out.append('"') catch {};
                out.appendSlice(entry.key_ptr.*) catch {};
                out.appendSlice("\":") catch {};
                writeJsonValue(out, entry.value_ptr.*);
            }
            out.append('}') catch return;
        },
        else => {},
    }
}

fn writeFloat(out: *std.ArrayList(u8), f: f64) void {
    var buf: [64]u8 = undefined;
    const rounded = @round(f * 100.0) / 100.0;
    const int_part: i64 = @intFromFloat(rounded);
    const frac = @abs(rounded - @as(f64, @floatFromInt(int_part)));
    const frac_int: u64 = @intFromFloat(@round(frac * 100.0));
    if (frac_int == 0) {
        const s = std.fmt.bufPrint(&buf, "{d}.0", .{int_part}) catch return;
        out.appendSlice(s) catch return;
    } else if (frac_int % 10 == 0) {
        const s = std.fmt.bufPrint(&buf, "{d}.{d}", .{ int_part, frac_int / 10 }) catch return;
        out.appendSlice(s) catch return;
    } else {
        const s = std.fmt.bufPrint(&buf, "{d}.{d:0>2}", .{ int_part, frac_int }) catch return;
        out.appendSlice(s) catch return;
    }
}

// ── Static files ────────────────────────────────────────────────────

fn loadStaticFiles() void {
    const alloc = std.heap.c_allocator;
    var dir = std.fs.openDirAbsolute("/data/static", .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (static_file_count >= 64) break;

        const file = dir.openFile(entry.name, .{}) catch continue;
        defer file.close();
        const data = file.readToEndAlloc(alloc, 1024 * 1024) catch continue;
        const name = alloc.dupe(u8, entry.name) catch continue;
        const ct = getContentType(entry.name);

        var resp = std.ArrayList(u8).init(alloc);
        var cl_buf: [32]u8 = undefined;
        resp.appendSlice("HTTP/1.1 200 OK\r\nServer: blitz\r\nContent-Type: ") catch continue;
        resp.appendSlice(ct) catch continue;
        resp.appendSlice("\r\nContent-Length: ") catch continue;
        resp.appendSlice(blitz.writeUsize(&cl_buf, data.len)) catch continue;
        resp.appendSlice("\r\n\r\n") catch continue;
        resp.appendSlice(data) catch continue;

        static_file_list[static_file_count] = .{
            .name = name,
            .response = resp.toOwnedSlice() catch continue,
        };
        static_file_count += 1;
    }
}

fn getContentType(name: []const u8) []const u8 {
    if (mem.endsWith(u8, name, ".css")) return "text/css";
    if (mem.endsWith(u8, name, ".js")) return "application/javascript";
    if (mem.endsWith(u8, name, ".html")) return "text/html";
    if (mem.endsWith(u8, name, ".woff2")) return "font/woff2";
    if (mem.endsWith(u8, name, ".svg")) return "image/svg+xml";
    if (mem.endsWith(u8, name, ".webp")) return "image/webp";
    if (mem.endsWith(u8, name, ".json")) return "application/json";
    return "application/octet-stream";
}

// ── Main ────────────────────────────────────────────────────────────

pub fn main() !void {
    // Load data
    dataset_json_resp = loadDataset("/data/dataset.json");
    loadStaticFiles();

    // Set up router
    const alloc = std.heap.c_allocator;
    var router = blitz.Router.init(alloc);

    // Register routes
    router.get("/pipeline", handlePipeline);
    router.get("/baseline11", handleBaseline);
    router.post("/baseline11", handleBaseline);
    router.get("/baseline2", handleBaseline2);
    router.get("/json", handleJson);
    router.post("/upload", handleUpload);
    router.get("/static/*filepath", handleStatic);

    // Check if io_uring backend is requested
    const use_uring = if (std.posix.getenv("BLITZ_URING")) |val| mem.eql(u8, val, "1") else false;

    if (use_uring) {
        var uring_server = blitz.UringServer.init(&router, .{
            .port = 8080,
            .compression = false,
        });
        try uring_server.listen();
    } else {
        var server = blitz.Server.init(&router, .{
            .port = 8080,
            .keep_alive_timeout = 0,
            .compression = false,
        });
        try server.listen();
    }
}
