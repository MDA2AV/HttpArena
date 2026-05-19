//! HttpArena `tuned` entry built on the zeemo Zig HTTP library.
//!
//! Handlers go through zeemo's framework HTTP server (no raw sockets),
//! JSON is serialized per request from native struct data via zeemo's
//! comptime serializer (no pre-rendered fragments), and static files are
//! cached + pre-baked at startup (allowed for `tuned`).

const std = @import("std");
const zeemo = @import("zeemo");
const dataset = @import("dataset.zig");

var DS: dataset.Dataset = undefined;
var STATIC: zeemo.static.Dir = undefined;

const STATIC_FILES = struct {
    const Entry = struct { name: []const u8, ct: []const u8, compress: bool };
    const all = [_]Entry{
        .{ .name = "reset.css", .ct = "text/css", .compress = true },
        .{ .name = "layout.css", .ct = "text/css", .compress = true },
        .{ .name = "theme.css", .ct = "text/css", .compress = true },
        .{ .name = "components.css", .ct = "text/css", .compress = true },
        .{ .name = "utilities.css", .ct = "text/css", .compress = true },
        .{ .name = "analytics.js", .ct = "application/javascript", .compress = true },
        .{ .name = "helpers.js", .ct = "application/javascript", .compress = true },
        .{ .name = "app.js", .ct = "application/javascript", .compress = true },
        .{ .name = "vendor.js", .ct = "application/javascript", .compress = true },
        .{ .name = "router.js", .ct = "application/javascript", .compress = true },
        .{ .name = "header.html", .ct = "text/html; charset=utf-8", .compress = true },
        .{ .name = "footer.html", .ct = "text/html; charset=utf-8", .compress = true },
        .{ .name = "regular.woff2", .ct = "font/woff2", .compress = false },
        .{ .name = "bold.woff2", .ct = "font/woff2", .compress = false },
        .{ .name = "logo.svg", .ct = "image/svg+xml", .compress = true },
        .{ .name = "icon-sprite.svg", .ct = "image/svg+xml", .compress = true },
        .{ .name = "hero.webp", .ct = "image/webp", .compress = false },
        .{ .name = "thumb1.webp", .ct = "image/webp", .compress = false },
        .{ .name = "thumb2.webp", .ct = "image/webp", .compress = false },
        .{ .name = "manifest.json", .ct = "application/json", .compress = true },
    };
};

pub fn main() !void {
    var dba: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dba.deinit();
    const gpa = dba.allocator();

    DS = try dataset.load(gpa, "/data/dataset.json");
    STATIC = zeemo.static.Dir.init(gpa, "/data/static");
    for (STATIC_FILES.all) |f|
        try STATIC.add(f.name, f.ct, .{ .compressible = f.compress });
    zeemo.static.setDir(&STATIC);
    std.log.info("zeemo-tuned: {d} items, {d} static files", .{ DS.items.len, STATIC.map.count() });

    var server = zeemo.Server.init(gpa, .{
        .port = 8080,
        // tuned-allowed knobs:
        .write_inline_bytes = 4 * 1024,
        // Sized for HttpArena's 20 MiB upload profile. The recv buffer
        // (parser_header_buf) collects raw bytes — headers + body — so
        // it has to be ≥ body size + headers room. Both buffers are
        // page_allocator-backed and lazily faulted: ~22 MiB virtual per
        // slot, near-zero RSS unless an upload actually lands.
        .parser_header_buf = 22 * 1024 * 1024,
        .parser_body_buf = 20 * 1024 * 1024,
        .big_buf_path_prefix = "/json/",
    });
    defer server.deinit();

    try server.get("/baseline11", baseline11);
    try server.post("/baseline11", baseline11);
    try server.get("/pipeline", pipeline);
    try server.get("/json/:count", jsonHandler);
    try server.post("/upload", uploadHandler);
    try server.staticMount("/static/", "/data/static", zeemo.static.registerHandler());

    try server.run();
}

fn baseline11(req: *const zeemo.Request, res: *zeemo.Response) !void {
    var sum: i64 = 0;
    if (req.queryInt("a", i64)) |a| sum += a;
    if (req.queryInt("b", i64)) |b| sum += b;
    if (req.method == .POST and req.body.len > 0) {
        sum += std.fmt.parseInt(i64, req.body, 10) catch 0;
    }
    try res.printText("{d}", .{sum});
}

fn pipeline(_: *const zeemo.Request, res: *zeemo.Response) !void {
    try res.text("ok");
}

fn uploadHandler(req: *const zeemo.Request, res: *zeemo.Response) !void {
    // HttpArena's `upload` profile sends a 20 MiB POST body and expects
    // the byte count back. The parser accumulates the full body in
    // `req.body` before we get here.
    try res.printText("{d}", .{req.body.len});
}

fn jsonHandler(req: *const zeemo.Request, res: *zeemo.Response) !void {
    const count = try req.param("count", u8);
    const m = req.queryInt("m", i64) orelse 1;
    if (count == 0 or count > DS.items.len) {
        res.status(400);
        try res.text("bad count");
        return;
    }
    var items: [50]dataset.Item = undefined;
    for (0..count) |i| {
        items[i] = DS.items[i];
        items[i].total = @as(i64, items[i].price) * @as(i64, items[i].quantity) * m;
    }
    // json-comp profile sets Accept-Encoding: gzip — same handler, just
    // gzip the body in place. json profile sends no Accept-Encoding and
    // takes the plain branch.
    if (req.accepts_gzip) {
        try res.jsonGzipped(.{
            .items = items[0..count],
            .count = @as(u32, count),
        });
    } else {
        try res.json(.{
            .items = items[0..count],
            .count = @as(u32, count),
        });
    }
}
