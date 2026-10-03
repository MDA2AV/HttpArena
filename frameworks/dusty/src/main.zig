const std = @import("std");
const zio = @import("zio");
const http = @import("dusty");
const json = @import("json");
const pg = @import("pg");

const flate = std.compress.flate;

var dataset: ?[]const DatasetItem = null;
var pool: ?*pg.Pool = null;

const Rating = struct { score: i64, count: i64 };

const DatasetItem = struct {
    id: i64,
    name: []const u8,
    category: []const u8,
    price: i64,
    quantity: i64,
    active: bool,
    tags: []const []const u8,
    rating: Rating,
};

const ResponseItem = struct {
    id: i64,
    name: []const u8,
    category: []const u8,
    price: i64,
    quantity: i64,
    active: bool,
    tags: []const []const u8,
    rating: Rating,
    total: i64,
};

fn loadDataset(allocator: std.mem.Allocator, io: std.Io) void {
    const file = std.Io.Dir.cwd().openFile(io, "/data/dataset.json", .{}) catch return;
    defer file.close(io);

    var read_buf: [8192]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    const decoded = json.decode([]const DatasetItem, allocator, &reader.interface, .{}) catch return;
    dataset = decoded.value;
}

fn baseline(req: *http.Request, res: *http.Response) !void {
    var sum: i64 = 0;
    var it = req.query.iterator();
    while (it.next()) |entry| {
        sum += std.fmt.parseInt(i64, entry.value, 10) catch 0;
    }
    if (req.method == .post) {
        if (try req.body()) |b| {
            sum += std.fmt.parseInt(i64, std.mem.trim(u8, b, " \t\r\n"), 10) catch 0;
        }
    }
    res.content_type = .text;
    var w = res.writer();
    try w.interface.print("{d}", .{sum});
    try w.end();
}

fn pipeline(_: *http.Request, res: *http.Response) !void {
    res.content_type = .text;
    res.body = "ok";
}

fn delay(req: *http.Request, res: *http.Response) !void {
    const ms = req.params.getInt(u32, "ms") orelse 0;
    if (ms > 0) {
        try req.io.sleep(.fromMilliseconds(@intCast(ms)), .awake);
    }
    res.content_type = .text;
    var w = res.writer();
    try w.interface.print("{d}", .{ms});
    try w.end();
}

fn acceptsGzip(headers: *const http.Headers) bool {
    const ae = headers.get("Accept-Encoding") orelse return false;
    return std.mem.indexOf(u8, ae, "gzip") != null;
}

fn jsonItems(req: *http.Request, res: *http.Response) !void {
    const items = dataset orelse {
        res.status = .service_unavailable;
        return;
    };

    const count = req.params.getInt(usize, "count") orelse {
        res.status = .bad_request;
        return;
    };
    if (count < 1 or count > items.len) {
        res.status = .bad_request;
        return;
    }

    const m: i64 = req.query.getInt(i64, "m") orelse 1;

    const resp_items = try req.arena.alloc(ResponseItem, count);
    for (items[0..count], 0..) |item, i| {
        resp_items[i] = .{
            .id = item.id,
            .name = item.name,
            .category = item.category,
            .price = item.price,
            .quantity = item.quantity,
            .active = item.active,
            .tags = item.tags,
            .rating = item.rating,
            .total = item.price * item.quantity * m,
        };
    }

    const payload = .{ .items = resp_items, .count = count };
    const want_gzip = acceptsGzip(&req.headers);

    if (want_gzip) {
        try res.header("Content-Encoding", "gzip");
        try res.header("Vary", "Accept-Encoding");
        try res.header("Content-Type", "application/json");

        var stream_buf: [4096]u8 = undefined;
        var body = try res.stream(&stream_buf);

        const window = try req.arena.alloc(u8, flate.max_window_len);
        var compressor = try flate.Compress.init(&body.interface, window, .gzip, .fastest);
        try json.encode(payload, &compressor.writer);
        try compressor.finish();
        try body.end();
    } else {
        try res.header("Content-Type", "application/json");
        var w = res.writer();
        try json.encode(payload, &w.interface);
        try w.end();
    }
}

const DbItem = struct {
    id: i32,
    name: []const u8,
    category: []const u8,
    price: i32,
    quantity: i32,
    active: bool,
    tags: []const []const u8,
    rating: Rating,
};

const DbResponse = struct {
    items: []const DbItem,
    count: usize,
};

const empty_db_response = DbResponse{ .items = &.{}, .count = 0 };

fn asyncDb(req: *http.Request, res: *http.Response) !void {
    const p = pool orelse {
        try res.header("Content-Type", "application/json");
        var w = res.writer();
        try json.encode(empty_db_response, &w.interface);
        try w.end();
        return;
    };

    const min = req.query.getInt(i32, "min") orelse 10;
    const max = req.query.getInt(i32, "max") orelse 50;
    const limit = std.math.clamp(req.query.getInt(i32, "limit") orelse 50, 1, 50);

    var result = p.query(
        "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3",
        .{ min, max, limit },
    ) catch {
        try res.header("Content-Type", "application/json");
        var w = res.writer();
        try json.encode(empty_db_response, &w.interface);
        try w.end();
        return;
    };
    defer result.deinit();

    var items: std.ArrayListUnmanaged(DbItem) = .empty;
    while (try result.next()) |row| {
        const tags_json = try row.get([]const u8, 6);
        const tags = json.decodeFromSliceLeaky([]const []const u8, req.arena, tags_json, .{}) catch &.{};

        try items.append(req.arena, DbItem{
            .id = try row.get(i32, 0),
            .name = try row.get([]const u8, 1),
            .category = try row.get([]const u8, 2),
            .price = try row.get(i32, 3),
            .quantity = try row.get(i32, 4),
            .active = try row.get(bool, 5),
            .tags = tags,
            .rating = .{
                .score = try row.get(i32, 7),
                .count = try row.get(i32, 8),
            },
        });
    }

    const payload = DbResponse{ .items = items.items, .count = items.items.len };
    try res.header("Content-Type", "application/json");
    var w = res.writer();
    try json.encode(payload, &w.interface);
    try w.end();
}

fn wsEcho(req: *http.Request, res: *http.Response) !void {
    var ws = try res.upgradeWebSocket(req) orelse {
        res.status = .not_found;
        return;
    };
    defer ws.deinit();
    while (true) {
        const msg = try ws.receive();
        switch (msg.type) {
            .text, .binary => try ws.send(msg.type, msg.data),
            .close => return,
            else => {},
        }
    }
}

fn echoBody(req: *http.Request, res: *http.Response) !void {
    const body = try req.body() orelse "";
    try res.header("Content-Type", "application/octet-stream");
    res.body = body;
}

pub fn main(init: std.process.Init) !void {
    var rt = try zio.Runtime.init(init.gpa, .{ .executors = .auto });
    defer rt.deinit();

    loadDataset(init.arena.allocator(), rt.io());

    if (init.environ_map.get("DATABASE_URL")) |url| {
        const uri = std.Uri.parse(url) catch @panic("invalid DATABASE_URL");
        const max_conn = if (init.environ_map.get("DATABASE_MAX_CONN")) |v|
            std.fmt.parseInt(u16, v, 10) catch 256
        else
            256;
        pool = pg.Pool.initUri(rt.io(), init.gpa, uri, .{
            .size = max_conn,
            .connect_on_init_count = 1,
        }) catch null;
    }

    var server = http.Server(void).init(init.gpa, rt.io(), .{
        .max_connections = 65_536,
    }, {});
    defer server.deinit();

    server.router.get("/baseline11", baseline);
    server.router.post("/baseline11", baseline);
    server.router.get("/baseline2", baseline);
    server.router.post("/baseline2", baseline);
    server.router.get("/pipeline", pipeline);
    server.router.get("/delay/:ms", delay);
    server.router.get("/json/:count", jsonItems);
    server.router.post("/echo", echoBody);
    server.router.get("/ws", wsEcho);
    server.router.get("/async-db", asyncDb);

    const addr: http.Address = .{ .ip = try std.Io.net.IpAddress.parse("0.0.0.0", 8080) };
    try server.listen(addr);
}
