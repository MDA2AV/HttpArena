const std = @import("std");
const uz = @import("uWebZockets");

const Port = struct {
    const h1 = 8080;
    const h1_tls = 8081;
    const h2c = 8082;
    const h2_h3 = 8443;
};

const json_body_max = 16 * 1024;
const gzip_level = 9;

fn routes(app: anytype) !void {
    _ = try app.get("/baseline11", baseline);
    _ = try app.post("/baseline11", baselineWithBody);
    _ = try app.get("/baseline2", baseline);
    _ = try app.get("/pipeline", pipeline);
    _ = try app.get("/json/:count", json);
    _ = try app.ws("/ws", .{ .message = wsMessage });
}

fn baseline(req: *uz.Request, res: *uz.Response) void {
    answer(req, res, false);
}

fn baselineWithBody(req: *uz.Request, res: *uz.Response) void {
    answer(req, res, true);
}

fn answer(req: *uz.Request, res: *uz.Response, with_body: bool) void {
    var sum = sumQuery(req);
    if (with_body) sum += parseIntLoose(req.text());

    var buffer: [24]u8 = undefined;
    const body = std.fmt.bufPrint(&buffer, "{d}", .{sum}) catch return;
    res.text(body) catch {};
}

fn sumQuery(req: *uz.Request) i64 {
    const params = req.query_params() catch return 0;
    var sum: i64 = 0;
    var iterator = params.pairs();
    while (iterator.next()) |pair| {
        sum += std.fmt.parseInt(i64, pair.value, 10) catch 0;
    }
    return sum;
}

fn parseIntLoose(text: []const u8) i64 {
    var index: usize = 0;
    while (index < text.len and (text[index] == ' ' or text[index] == '\r' or text[index] == '\n')) index += 1;

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

fn pipeline(_: *uz.Request, res: *uz.Response) void {
    res.text("ok") catch {};
}

fn wsMessage(socket: *uz.WebSocket, message: []const u8, opcode: uz.Opcode) void {
    socket.send(message, opcode) catch {};
}

const Rating = struct {
    score: i64,
    count: i64,
};

const Item = struct {
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

const ResponseBody = struct {
    items: []const ResponseItem,
    count: usize,
};

threadlocal var response_items: [50]ResponseItem = undefined;

var http_ready = std.atomic.Value(bool).init(false);
var dataset_raw: []u8 = &.{};
var dataset_parsed: ?std.json.Parsed([]const Item) = null;

fn json(req: *uz.Request, res: *uz.Response) void {
    const rows = datasetItems() orelse return status(res, "503 Service Unavailable");

    const count_text = req.get_param("count") orelse return status(res, "400 Bad Request");
    const count = std.fmt.parseInt(usize, count_text, 10) catch return status(res, "400 Bad Request");
    if (count < 1 or count > rows.len or count > response_items.len) return status(res, "400 Bad Request");

    const params = req.query_params() catch return status(res, "400 Bad Request");
    const multiplier = (params.get_int(u32, "m") catch 1) orelse 1;

    var rendered_buffer: [json_body_max]u8 = undefined;
    const rendered = std.fmt.bufPrint(
        &rendered_buffer,
        "{f}",
        .{std.json.fmt(render(rows, count, multiplier), .{})},
    ) catch return status(res, "500 Internal Server Error");

    if (req.header_has_token("accept-encoding", "gzip")) {
        var input: [json_body_max]u8 = undefined;
        var output: [json_body_max]u8 = undefined;
        const compressed = gzip(rendered, &input, &output) catch
            return status(res, "500 Internal Server Error");

        res.end_with_headers(
            "200 OK",
            "Content-Type: application/json; charset=utf-8\r\nContent-Encoding: gzip\r\n",
            compressed,
        ) catch {};
        return;
    }

    res.end_with_headers("200 OK", "Content-Type: application/json; charset=utf-8\r\n", rendered) catch {};
}

fn render(rows: []const Item, count: usize, multiplier: u32) ResponseBody {
    for (rows[0..count], 0..) |row, index| {
        response_items[index] = .{
            .id = row.id,
            .name = row.name,
            .category = row.category,
            .price = row.price,
            .quantity = row.quantity,
            .active = row.active,
            .tags = row.tags,
            .rating = row.rating,
            .total = row.price * row.quantity * @as(i64, @intCast(multiplier)),
        };
    }
    return .{ .items = response_items[0..count], .count = count };
}

fn gzip(body: []const u8, input: []u8, output: []u8) ![]const u8 {
    var stream = try uz.compression_stream.CompressionStream.init(.gzip, gzip_level, input);
    defer stream.deinit();

    try stream.write(body);
    if (stream.output_bound() > output.len) return error.BufferTooSmall;
    return stream.finish(output);
}

fn status(res: *uz.Response, text: []const u8) void {
    res.end(text, "") catch {};
}

const dataset_file_max = 4 * 1024 * 1024;

fn loadDataset(init: std.process.Init) void {
    dataset_raw = readFile(init, datasetPath(init)) catch return;
    dataset_parsed = std.json.parseFromSlice(
        []const Item,
        std.heap.page_allocator,
        dataset_raw,
        .{},
    ) catch return;
}

fn datasetItems() ?[]const Item {
    if (dataset_parsed) |*value| return value.value;
    return null;
}

fn readFile(init: std.process.Init, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(init.io, path, .{ .allow_directory = false });
    defer file.close(init.io);

    const stat = try file.stat(init.io);
    if (stat.size == 0 or stat.size > dataset_file_max) return error.BadDatasetSize;

    const buffer = try std.heap.page_allocator.alloc(u8, @intCast(stat.size));
    const read = try file.readPositionalAll(init.io, buffer, 0);
    if (read != buffer.len) return error.UnexpectedEndOfFile;
    return buffer;
}

fn datasetPath(init: std.process.Init) []const u8 {
    return init.environ_map.get("UZ_DATASET") orelse "/data/dataset.json";
}

fn clusterConfig(comptime connections: usize) uz.ServerConfig {
    var config = uz.ServerConfig{};
    config.max_connections = connections;
    config.max_request_line_size = 1024;
    config.max_header_size = 4096;
    config.max_body_size = 2048;
    config.write_queue_size = 16 * 1024;
    config.max_h2_header_block_size = 2048;
    config.max_h2_body_size = 512;
    config.max_h2_response_header_size = 1024;
    config.max_h2_response_header_count = 24;
    config.enable_dev_log = false;
    return config;
}

fn h2cConfig(comptime connections: usize) uz.ServerConfig {
    var config = clusterConfig(connections);
    config.max_h2_header_block_size = 4096;
    config.max_h2_body_size = 16 * 1024;
    config.max_h2_response_header_size = 2048;
    config.max_h2_response_header_count = 32;
    return config;
}

fn runCluster(init: std.process.Init, comptime config: uz.ServerConfig, comptime workers: usize, port: u16, is_http: bool) !void {
    var group = try uz.Server.preset(init.io, config).build_cluster(
        std.heap.page_allocator,
        workers,
        .{},
    );
    defer group.deinit();

    const Cluster = @TypeOf(group);
    try group.configure(struct {
        fn call(worker: *Cluster.Worker, _: usize) !void {
            try routes(worker);
        }
    }.call);

    try group.listen("0.0.0.0", port);
    if (is_http) http_ready.store(true, .release);
    try group.run();
}

fn httpMode(init: std.process.Init) !void {

    const cpus = std.Thread.getCpuCount() catch 8;
    if (cpus >= 64) return runCluster(init, clusterConfig(768), 32, Port.h1, true);
    if (cpus >= 32) return runCluster(init, clusterConfig(1280), 16, Port.h1, true);
    if (cpus >= 16) return runCluster(init, clusterConfig(2560), 8, Port.h1, true);
    return runCluster(init, clusterConfig(5120), 4, Port.h1, true);
}

fn h2cMode(init: std.process.Init) !void {
    while (!http_ready.load(.acquire)) init.io.sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    const cpus = std.Thread.getCpuCount() catch 8;
    if (cpus >= 64) return runCluster(init, h2cConfig(256), 32, Port.h2c, false);
    if (cpus >= 32) return runCluster(init, h2cConfig(512), 16, Port.h2c, false);
    if (cpus >= 16) return runCluster(init, h2cConfig(1024), 8, Port.h2c, false);
    return runCluster(init, h2cConfig(2048), 4, Port.h2c, false);
}

fn tlsMode(init: std.process.Init) !void {
    while (!http_ready.load(.acquire)) init.io.sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    var app = try uz.App(5120).init_https(
        init.io,
        try nullTerminated(init, certPath(init)),
        try nullTerminated(init, keyPath(init)),
    );
    defer app.deinit();

    try routes(&app);
    try app.listen("0.0.0.0", Port.h1_tls);
    try app.run();
}

fn h3Mode(init: std.process.Init) !void {
    while (!http_ready.load(.acquire)) init.io.sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    var app = try uz.App(1280).init_http3(
        init.io,
        try nullTerminated(init, certPath(init)),
        try nullTerminated(init, keyPath(init)),
    );
    defer app.deinit();

    try routes(&app);
    try app.listen("0.0.0.0", Port.h2_h3);
    try app.listen_udp("0.0.0.0", Port.h2_h3);
    try app.run();
}

fn certPath(init: std.process.Init) []const u8 {
    return init.environ_map.get("UZ_CERT") orelse "/certs/server.crt";
}

fn keyPath(init: std.process.Init) []const u8 {
    return init.environ_map.get("UZ_KEY") orelse "/certs/server.key";
}

fn nullTerminated(init: std.process.Init, value: []const u8) ![:0]u8 {
    const buffer = try init.gpa.allocSentinel(u8, value.len, 0);
    @memcpy(buffer, value);
    return buffer;
}

const Mode = enum { http, h2c, tls, h3 };

fn serve(init: std.process.Init, mode: Mode) void {
    const result = switch (mode) {
        .http => httpMode(init),
        .h2c => h2cMode(init),
        .tls => tlsMode(init),
        .h3 => h3Mode(init),
    };
    result catch |err| std.log.err("listener {s} stopped: {s}", .{ @tagName(mode), @errorName(err) });
}

pub fn main(init: std.process.Init) !void {
    loadDataset(init);

    var threads: [4]std.Thread = undefined;
    threads[0] = try std.Thread.spawn(.{}, serve, .{ init, Mode.http });
    threads[1] = try std.Thread.spawn(.{}, serve, .{ init, Mode.h2c });
    threads[2] = try std.Thread.spawn(.{}, serve, .{ init, Mode.tls });
    threads[3] = try std.Thread.spawn(.{}, serve, .{ init, Mode.h3 });
    for (threads) |thread| thread.join();
}
