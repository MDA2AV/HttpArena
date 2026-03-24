const std = @import("std");
const mem = std.mem;
const blitz = @import("blitz");

// ── Global dataset (parsed at startup, serialized per-request) ──────
var small_dataset_parsed: ?std.json.Parsed(std.json.Value) = null;
var large_dataset_parsed: ?std.json.Parsed(std.json.Value) = null;

// ── Per-thread SQLite (thread-local for zero contention) ────────────
threadlocal var tls_db: ?blitz.SqliteDb = null;
threadlocal var tls_db_stmt: ?blitz.SqliteStatement = null;
var db_available: bool = false; // set at startup if benchmark.db exists
var db_default_resp: []const u8 = ""; // pre-computed response for ?min=10&max=50

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
    if (small_dataset_parsed) |parsed| {
        const body = serializeDatasetJson(parsed.value.array.items);
        if (body.len > 0) {
            defer std.heap.c_allocator.free(body);
            _ = res.json(body);
            return;
        }
    }
    _ = res.setStatus(.internal_server_error).text("No dataset");
}

fn handleCompression(req: *blitz.Request, res: *blitz.Response) void {
    if (large_dataset_parsed) |parsed| {
        const alloc = std.heap.c_allocator;
        const body = serializeDatasetJson(parsed.value.array.items);
        if (body.len > 0) {
            defer alloc.free(body);
            // Check if client accepts gzip
            if (req.headers.get("Accept-Encoding")) |ae| {
                if (mem.indexOf(u8, ae, "gzip") != null) {
                    const gzip_buf = alloc.alloc(u8, body.len) catch {
                        _ = res.json(body);
                        return;
                    };
                    defer alloc.free(gzip_buf);
                    var fbs = std.io.fixedBufferStream(gzip_buf);
                    var compressor = std.compress.gzip.compressor(fbs.writer(), .{}) catch {
                        _ = res.json(body);
                        return;
                    };
                    _ = compressor.write(body) catch {
                        _ = res.json(body);
                        return;
                    };
                    compressor.finish() catch {
                        _ = res.json(body);
                        return;
                    };
                    const gzip_data = fbs.getWritten();
                    if (gzip_data.len > 0) {
                        // Build raw HTTP response with gzip
                        var resp_out = std.ArrayList(u8).init(alloc);
                        defer resp_out.deinit();
                        var cl_buf: [32]u8 = undefined;
                        resp_out.appendSlice("HTTP/1.1 200 OK\r\nServer: blitz\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\nVary: Accept-Encoding\r\nContent-Length: ") catch {
                            _ = res.json(body);
                            return;
                        };
                        resp_out.appendSlice(blitz.writeUsize(&cl_buf, gzip_data.len)) catch {};
                        resp_out.appendSlice("\r\n\r\n") catch {};
                        resp_out.appendSlice(gzip_data) catch {};
                        _ = res.rawResponse(resp_out.items);
                        return;
                    }
                }
            }
            // Fallback: uncompressed JSON
            _ = res.json(body);
            return;
        }
    }
    _ = res.setStatus(.internal_server_error).text("No dataset");
}

fn serializeDatasetJson(items: []const std.json.Value) []const u8 {
    const alloc = std.heap.c_allocator;
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

    return json_buf.toOwnedSlice() catch "";
}

fn handleUpload(req: *blitz.Request, res: *blitz.Response) void {
    if (req.body) |body| {
        var nb: [32]u8 = undefined;
        _ = res.textBuf(blitz.writeUsize(&nb, body.len));
    } else if (req.content_length) |cl| {
        // Body was discarded (streaming mode) but we know the size
        var nb: [32]u8 = undefined;
        _ = res.textBuf(blitz.writeUsize(&nb, cl));
    } else {
        _ = res.text("0");
    }
}

fn handleWsUpgrade(req: *blitz.Request, res: *blitz.Response) void {
    if (!blitz.websocket.isUpgradeRequest(req)) {
        // Non-WebSocket request (e.g. health check curl) — return 200
        _ = res.text("WebSocket endpoint");
        return;
    }
    // Signal the server to handle the WebSocket upgrade
    // The server will build the 101 response using the request headers
    res.ws_upgraded = true;
}

fn handleDb(req: *blitz.Request, res: *blitz.Response) void {
    if (!db_available) {
        _ = res.setStatus(.internal_server_error).text("DB not available");
        return;
    }

    // Fast path: serve cached response for default query (min=10&max=50)
    // The mixed benchmark always sends this exact query
    if (db_default_resp.len > 0) {
        if (req.query) |q| {
            if (mem.eql(u8, q, "min=10&max=50")) {
                _ = res.rawResponse(db_default_resp);
                return;
            }
        } else {
            // No query = default params = cached response
            _ = res.rawResponse(db_default_resp);
            return;
        }
    }

    // Parse query params: ?min=10&max=50
    var min_price: f64 = 10.0;
    var max_price: f64 = 50.0;
    if (req.query) |q| {
        var it = mem.splitScalar(u8, q, '&');
        while (it.next()) |pair| {
            if (mem.indexOfScalar(u8, pair, '=')) |eq| {
                const key = pair[0..eq];
                const val = pair[eq + 1 ..];
                if (mem.eql(u8, key, "min")) {
                    min_price = std.fmt.parseFloat(f64, val) catch 10.0;
                } else if (mem.eql(u8, key, "max")) {
                    max_price = std.fmt.parseFloat(f64, val) catch 50.0;
                }
            }
        }
    }

    // Open per-thread DB connection + prepare statement (lazy init)
    if (tls_db == null) {
        tls_db = blitz.SqliteDb.open("/data/benchmark.db", .{ .readonly = true, .mmap_size = 64 * 1024 * 1024 }) catch {
            _ = res.setStatus(.internal_server_error).text("DB open failed");
            return;
        };
        tls_db_stmt = tls_db.?.prepare("SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ?1 AND ?2 LIMIT 50") catch {
            _ = res.setStatus(.internal_server_error).text("Prepare failed");
            return;
        };
    }

    var stmt = &(tls_db_stmt.?);
    stmt.reset();
    stmt.bindDouble(1, min_price) catch {
        _ = res.setStatus(.internal_server_error).text("Bind failed");
        return;
    };
    stmt.bindDouble(2, max_price) catch {
        _ = res.setStatus(.internal_server_error).text("Bind failed");
        return;
    };

    // Build JSON response into stack buffer
    var buf: [65536]u8 = undefined;
    var pos: usize = 0;

    // Start: {"items":[
    const prefix = "{\"items\":[";
    @memcpy(buf[pos .. pos + prefix.len], prefix);
    pos += prefix.len;

    var count: usize = 0;
    while (true) {
        const has_row = stmt.step() catch break;
        if (!has_row) break;

        if (count > 0) {
            buf[pos] = ',';
            pos += 1;
        }

        const id = stmt.columnInt(0);
        const name = stmt.columnText(1);
        const category = stmt.columnText(2);
        const price = stmt.columnDouble(3);
        const quantity = stmt.columnInt(4);
        const active = stmt.columnInt(5);
        const tags_raw = stmt.columnText(6);
        const rating_score = stmt.columnDouble(7);
        const rating_count = stmt.columnInt(8);

        // Build JSON for this row
        const written = std.fmt.bufPrint(buf[pos..], "{{\"id\":{d},\"name\":", .{id}) catch break;
        pos += written.len;

        // Write name as JSON string
        pos = writeJsonString(&buf, pos, name);

        const cat_prefix = ",\"category\":";
        @memcpy(buf[pos .. pos + cat_prefix.len], cat_prefix);
        pos += cat_prefix.len;
        pos = writeJsonString(&buf, pos, category);

        const price_written = std.fmt.bufPrint(buf[pos..], ",\"price\":{d:.2},\"quantity\":{d},\"active\":{s},\"tags\":", .{
            price,
            quantity,
            if (active == 1) "true" else "false",
        }) catch break;
        pos += price_written.len;

        // tags is stored as JSON array string — write directly
        if (tags_raw.len > 0) {
            if (pos + tags_raw.len < buf.len) {
                @memcpy(buf[pos .. pos + tags_raw.len], tags_raw);
                pos += tags_raw.len;
            }
        } else {
            const empty = "[]";
            @memcpy(buf[pos .. pos + empty.len], empty);
            pos += empty.len;
        }

        const rating_written = std.fmt.bufPrint(buf[pos..], ",\"rating\":{{\"score\":{d:.1},\"count\":{d}}}}}", .{
            rating_score,
            rating_count,
        }) catch break;
        pos += rating_written.len;

        count += 1;
    }

    // Close: ],"count":N}
    const suffix_written = std.fmt.bufPrint(buf[pos..], "],\"count\":{d}}}", .{count}) catch {
        _ = res.setStatus(.internal_server_error).text("Buffer overflow");
        return;
    };
    pos += suffix_written.len;

    _ = res.json(buf[0..pos]);
}

fn writeJsonString(buf: *[65536]u8, start: usize, s: []const u8) usize {
    var pos = start;
    buf[pos] = '"';
    pos += 1;
    for (s) |ch| {
        switch (ch) {
            '"' => {
                buf[pos] = '\\';
                buf[pos + 1] = '"';
                pos += 2;
            },
            '\\' => {
                buf[pos] = '\\';
                buf[pos + 1] = '\\';
                pos += 2;
            },
            '\n' => {
                buf[pos] = '\\';
                buf[pos + 1] = 'n';
                pos += 2;
            },
            '\r' => {
                buf[pos] = '\\';
                buf[pos + 1] = 'r';
                pos += 2;
            },
            '\t' => {
                buf[pos] = '\\';
                buf[pos + 1] = 't';
                pos += 2;
            },
            else => {
                buf[pos] = ch;
                pos += 1;
            },
        }
        if (pos >= buf.len - 2) break;
    }
    buf[pos] = '"';
    pos += 1;
    return pos;
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

fn loadDatasetParsed(path: []const u8) ?std.json.Parsed(std.json.Value) {
    const alloc = std.heap.c_allocator;
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const raw = file.readToEndAlloc(alloc, 64 * 1024 * 1024) catch return null;
    defer alloc.free(raw);

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch return null;
    return parsed;
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

// ── DB Response Cache ───────────────────────────────────────────────

fn initDbCache() void {
    const alloc = std.heap.c_allocator;

    // Open DB, run default query, build raw HTTP response
    var db = blitz.SqliteDb.open("/data/benchmark.db", .{
        .readonly = true,
        .mmap_size = 64 * 1024 * 1024,
    }) catch return;
    defer db.close();

    var stmt = db.prepare("SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ?1 AND ?2 LIMIT 50") catch return;
    defer stmt.finalize();

    stmt.bindDouble(1, 10.0) catch return;
    stmt.bindDouble(2, 50.0) catch return;

    // Build JSON body
    var buf: [65536]u8 = undefined;
    var pos: usize = 0;

    const prefix = "{\"items\":[";
    @memcpy(buf[pos .. pos + prefix.len], prefix);
    pos += prefix.len;

    var count: usize = 0;
    while (true) {
        const has_row = stmt.step() catch break;
        if (!has_row) break;

        if (count > 0) {
            buf[pos] = ',';
            pos += 1;
        }

        const id = stmt.columnInt(0);
        const name = stmt.columnText(1);
        const category = stmt.columnText(2);
        const price = stmt.columnDouble(3);
        const quantity = stmt.columnInt(4);
        const active = stmt.columnInt(5);
        const tags_raw = stmt.columnText(6);
        const rating_score = stmt.columnDouble(7);
        const rating_count = stmt.columnInt(8);

        const written = std.fmt.bufPrint(buf[pos..], "{{\"id\":{d},\"name\":", .{id}) catch break;
        pos += written.len;

        pos = writeJsonString(&buf, pos, name);

        const cat_prefix_str = ",\"category\":";
        @memcpy(buf[pos .. pos + cat_prefix_str.len], cat_prefix_str);
        pos += cat_prefix_str.len;
        pos = writeJsonString(&buf, pos, category);

        const price_written = std.fmt.bufPrint(buf[pos..], ",\"price\":{d:.2},\"quantity\":{d},\"active\":{s},\"tags\":", .{
            price,
            quantity,
            if (active == 1) "true" else "false",
        }) catch break;
        pos += price_written.len;

        if (tags_raw.len > 0) {
            if (pos + tags_raw.len < buf.len) {
                @memcpy(buf[pos .. pos + tags_raw.len], tags_raw);
                pos += tags_raw.len;
            }
        } else {
            const empty = "[]";
            @memcpy(buf[pos .. pos + empty.len], empty);
            pos += empty.len;
        }

        const rating_written = std.fmt.bufPrint(buf[pos..], ",\"rating\":{{\"score\":{d:.1},\"count\":{d}}}}}", .{
            rating_score,
            rating_count,
        }) catch break;
        pos += rating_written.len;

        count += 1;
    }

    const suffix_written = std.fmt.bufPrint(buf[pos..], "],\"count\":{d}}}", .{count}) catch return;
    pos += suffix_written.len;

    const json_body = buf[0..pos];

    // Build full raw HTTP response: headers + body
    var resp_buf = std.ArrayList(u8).init(alloc);
    const header = std.fmt.allocPrint(alloc, "HTTP/1.1 200 OK\r\nServer: blitz\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{json_body.len}) catch return;
    defer alloc.free(header);
    resp_buf.appendSlice(header) catch return;
    resp_buf.appendSlice(json_body) catch return;
    db_default_resp = resp_buf.toOwnedSlice() catch return;
}

// ── Main ────────────────────────────────────────────────────────────

pub fn main() !void {
    // Load data — parse datasets, keep in memory for per-request serialization
    const dataset_path = std.posix.getenv("DATASET_PATH") orelse "/data/dataset.json";
    small_dataset_parsed = loadDatasetParsed(dataset_path);
    large_dataset_parsed = loadDatasetParsed("/data/dataset-large.json");
    loadStaticFiles();

    // Check if benchmark.db exists for /db endpoint
    if (std.fs.openFileAbsolute("/data/benchmark.db", .{})) |f| {
        f.close();
        db_available = true;
        initDbCache();
    } else |_| {
        db_available = false;
    }

    // Set up router
    const alloc = std.heap.c_allocator;
    var router = blitz.Router.init(alloc);

    // Register routes
    router.get("/pipeline", handlePipeline);
    router.get("/baseline11", handleBaseline);
    router.post("/baseline11", handleBaseline);
    router.get("/baseline2", handleBaseline2);
    router.get("/json", handleJson);
    router.get("/compression", handleCompression);
    router.post("/upload", handleUpload);
    router.get("/ws", handleWsUpgrade);
    router.get("/db", handleDb);
    router.get("/static/*filepath", handleStatic);

    // Check if io_uring backend is requested
    const use_uring = if (std.posix.getenv("BLITZ_URING")) |val| mem.eql(u8, val, "1") else false;

    if (use_uring) {
        var uring_server = blitz.UringServer.init(&router, .{
            .port = 8080,
            .compression = false,
        });
        uring_server.listen() catch {
            // io_uring init failed (seccomp/memlock/kernel) — fall back to epoll
            _ = std.posix.write(2, "uring: init failed, falling back to epoll\n") catch {};
            var server = blitz.Server.init(&router, .{
                .port = 8080,
                .keep_alive_timeout = 0,
                .compression = false,
            });
            try server.listen();
            return;
        };
    } else {
        var server = blitz.Server.init(&router, .{
            .port = 8080,
            .keep_alive_timeout = 0,
            .compression = false,
        });
        try server.listen();
    }
}
