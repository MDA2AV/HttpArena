const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const mem = std.mem;
const Thread = std.Thread;

// ── Constants ────────────────────────────────────────────────────────
const SERVER_HDR = "Server: blitz\r\n";
const CT_PLAIN = "Content-Type: text/plain\r\n";
const CT_JSON = "Content-Type: application/json\r\n";
const PIPELINE_RESP = "HTTP/1.1 200 OK\r\n" ++ SERVER_HDR ++ CT_PLAIN ++ "Content-Length: 2\r\n\r\nok";
const NOT_FOUND_RESP = "HTTP/1.1 404 Not Found\r\n" ++ SERVER_HDR ++ "Content-Length: 0\r\n\r\n";
const METHOD_NOT_ALLOWED_RESP = "HTTP/1.1 405 Method Not Allowed\r\n" ++ SERVER_HDR ++ "Content-Length: 0\r\n\r\n";

const PORT: u16 = 8080;
const MAX_EVENTS: usize = 512;
const BUF_SIZE: usize = 65536;
const MAX_REQUEST_SIZE: usize = 4 * 1024 * 1024; // 4MB max request
const MAX_CONNS: usize = 65536;

// Linux socket constants
const SOCK_STREAM: u32 = linux.SOCK.STREAM;
const SOCK_NONBLOCK: u32 = linux.SOCK.NONBLOCK;
const AF_INET: u32 = linux.AF.INET;
const SOL_SOCKET: i32 = 1;
const SO_REUSEPORT: u32 = 15;
const SO_REUSEADDR: u32 = 2;
const IPPROTO_TCP: i32 = 6;
const TCP_NODELAY: u32 = 1;

// ── Global state ─────────────────────────────────────────────────────
var dataset_json_resp: []const u8 = "";

const StaticFile = struct {
    name: []const u8,
    response: []const u8,
};

var static_file_list: [64]StaticFile = undefined;
var static_file_count: usize = 0;

fn findStaticFile(name: []const u8) ?[]const u8 {
    for (0..static_file_count) |i| {
        if (mem.eql(u8, static_file_list[i].name, name))
            return static_file_list[i].response;
    }
    return null;
}

// ── Helpers ──────────────────────────────────────────────────────────

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

fn writeI64(buf: []u8, val: i64) []const u8 {
    var v = val;
    var neg = false;
    if (v < 0) { neg = true; v = -v; }
    var i: usize = buf.len;
    if (v == 0) { i -= 1; buf[i] = '0'; } else {
        while (v > 0) {
            i -= 1;
            buf[i] = @intCast(@as(u64, @intCast(@mod(v, 10))) + '0');
            v = @divTrunc(v, 10);
        }
    }
    if (neg) { i -= 1; buf[i] = '-'; }
    return buf[i..];
}

fn writeUsize(buf: []u8, val: usize) []const u8 {
    var v = val;
    var i: usize = buf.len;
    if (v == 0) { i -= 1; buf[i] = '0'; } else {
        while (v > 0) { i -= 1; buf[i] = @intCast(v % 10 + '0'); v /= 10; }
    }
    return buf[i..];
}

// ── Per-connection state ────────────────────────────────────────────
const ConnState = struct {
    read_buf: [BUF_SIZE]u8 = undefined,
    read_len: usize = 0,
    // Dynamic overflow buffer for large requests (e.g. uploads)
    overflow_buf: ?[]u8 = null,
    overflow_len: usize = 0,
    overflow_alloc: std.mem.Allocator = std.heap.c_allocator,
    write_list: std.ArrayList(u8),
    write_off: usize = 0,

    fn init(alloc: std.mem.Allocator) ConnState {
        return .{ .write_list = std.ArrayList(u8).init(alloc), .overflow_alloc = alloc };
    }
    fn deinit(self: *ConnState) void {
        if (self.overflow_buf) |buf| self.overflow_alloc.free(buf);
        self.write_list.deinit();
    }

    /// Get readable data slice (either from fixed buf or overflow)
    fn readableData(self: *ConnState) []const u8 {
        if (self.overflow_buf) |buf| return buf[0..self.overflow_len];
        return self.read_buf[0..self.read_len];
    }

    /// Total data length
    fn dataLen(self: *ConnState) usize {
        if (self.overflow_buf != null) return self.overflow_len;
        return self.read_len;
    }

    /// Promote fixed buf data to overflow if we need more room
    fn ensureOverflow(self: *ConnState, needed: usize) !void {
        if (self.overflow_buf == null) {
            const cap = @max(needed, BUF_SIZE * 2);
            if (cap > MAX_REQUEST_SIZE) return error.RequestTooLarge;
            const buf = try self.overflow_alloc.alloc(u8, cap);
            @memcpy(buf[0..self.read_len], self.read_buf[0..self.read_len]);
            self.overflow_buf = buf;
            self.overflow_len = self.read_len;
            self.read_len = 0;
        } else if (self.overflow_len + needed > self.overflow_buf.?.len) {
            const new_cap = @max(self.overflow_len + needed, self.overflow_buf.?.len * 2);
            if (new_cap > MAX_REQUEST_SIZE) return error.RequestTooLarge;
            const new_buf = try self.overflow_alloc.alloc(u8, new_cap);
            @memcpy(new_buf[0..self.overflow_len], self.overflow_buf.?[0..self.overflow_len]);
            self.overflow_alloc.free(self.overflow_buf.?);
            self.overflow_buf = new_buf;
        }
    }

    /// Consume processed bytes, shift remainder
    fn consume(self: *ConnState, off: usize) void {
        if (self.overflow_buf) |buf| {
            const rem = self.overflow_len - off;
            if (rem > 0) std.mem.copyForwards(u8, buf[0..rem], buf[off..self.overflow_len]);
            self.overflow_len = rem;
            // If we're back to small data, drop overflow
            if (rem <= BUF_SIZE) {
                @memcpy(self.read_buf[0..rem], buf[0..rem]);
                self.read_len = rem;
                self.overflow_alloc.free(buf);
                self.overflow_buf = null;
                self.overflow_len = 0;
            }
        } else {
            const rem = self.read_len - off;
            if (rem > 0) std.mem.copyForwards(u8, self.read_buf[0..rem], self.read_buf[off..self.read_len]);
            self.read_len = rem;
        }
    }
};

// ── HTTP parsing ────────────────────────────────────────────────────
const Request = struct {
    method: []const u8,
    path: []const u8,
    query: ?[]const u8,
    body: ?[]const u8,
    total_len: usize,
};

fn parseRequest(data: []const u8) ?Request {
    const hdr_end_idx = mem.indexOf(u8, data, "\r\n\r\n") orelse return null;
    const hdr = data[0..hdr_end_idx];
    const req_end = mem.indexOf(u8, hdr, "\r\n") orelse return null;
    const req_line = hdr[0..req_end];

    const sp1 = mem.indexOfScalar(u8, req_line, ' ') orelse return null;
    const method = req_line[0..sp1];
    const rest = req_line[sp1 + 1 ..];
    const sp2 = mem.indexOfScalar(u8, rest, ' ') orelse return null;
    const uri = rest[0..sp2];

    var path = uri;
    var query: ?[]const u8 = null;
    if (mem.indexOfScalar(u8, uri, '?')) |qp| {
        path = uri[0..qp];
        query = uri[qp + 1 ..];
    }

    // Parse headers for Content-Length and Transfer-Encoding
    var content_length: ?usize = null;
    var chunked = false;
    var line_it = mem.splitSequence(u8, hdr, "\r\n");
    _ = line_it.next(); // skip request line
    while (line_it.next()) |line| {
        if (line.len >= 16) {
            if ((line[0] == 'C' or line[0] == 'c') and asciiEqlIgnoreCase(line[0..15], "content-length:")) {
                const val = mem.trimLeft(u8, line[15..], " ");
                content_length = std.fmt.parseInt(usize, val, 10) catch null;
            }
        }
        if (line.len >= 26) {
            if ((line[0] == 'T' or line[0] == 't') and asciiEqlIgnoreCase(line[0..18], "transfer-encoding:")) {
                const val = mem.trimLeft(u8, line[18..], " ");
                if (asciiEqlIgnoreCase(val[0..@min(val.len, 7)], "chunked")) {
                    chunked = true;
                }
            }
        }
    }

    const body_start = hdr_end_idx + 4;

    if (chunked) {
        const remaining = data[body_start..];
        // Find "0\r\n\r\n" end of chunked encoding
        if (mem.indexOf(u8, remaining, "0\r\n\r\n")) |end_pos| {
            const total = body_start + end_pos + 5;
            if (total > data.len) return null;
            // Parse first chunk
            const chunk_body = parseFirstChunk(remaining[0..end_pos]);
            return Request{ .method = method, .path = path, .query = query, .body = chunk_body, .total_len = total };
        }
        // Also try "0\r\n" at end
        if (mem.indexOf(u8, remaining, "\r\n0\r\n")) |end_pos| {
            const total = body_start + end_pos + 5;
            if (total > data.len) return null;
            const chunk_body = parseFirstChunk(remaining[0..end_pos]);
            return Request{ .method = method, .path = path, .query = query, .body = chunk_body, .total_len = total };
        }
        return null;
    }

    if (content_length) |cl| {
        if (data.len < body_start + cl) return null;
        return Request{ .method = method, .path = path, .query = query, .body = data[body_start .. body_start + cl], .total_len = body_start + cl };
    }

    return Request{ .method = method, .path = path, .query = query, .body = null, .total_len = body_start };
}

fn parseFirstChunk(data: []const u8) ?[]const u8 {
    const crlf = mem.indexOf(u8, data, "\r\n") orelse return null;
    const size = std.fmt.parseInt(usize, data[0..crlf], 16) catch return null;
    if (size == 0) return "";
    const start = crlf + 2;
    if (data.len < start + size) return null;
    return data[start .. start + size];
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la: u8 = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb: u8 = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

// ── Request handling ────────────────────────────────────────────────

fn isGetOrPost(method: []const u8) bool {
    return mem.eql(u8, method, "GET") or mem.eql(u8, method, "POST");
}

fn isGet(method: []const u8) bool {
    return mem.eql(u8, method, "GET");
}

fn handleRequest(req: *const Request, out: *std.ArrayList(u8)) void {
    const path = req.path;

    if (path.len == 9 and mem.eql(u8, path, "/pipeline")) {
        if (!isGet(req.method)) { out.appendSlice(METHOD_NOT_ALLOWED_RESP) catch return; return; }
        out.appendSlice(PIPELINE_RESP) catch return;
        return;
    }

    if (path.len == 11 and mem.eql(u8, path, "/baseline11")) {
        if (!isGetOrPost(req.method)) { out.appendSlice(METHOD_NOT_ALLOWED_RESP) catch return; return; }
        handleBaseline(req, out);
        return;
    }

    if (path.len == 10 and mem.eql(u8, path, "/baseline2")) {
        if (!isGetOrPost(req.method)) { out.appendSlice(METHOD_NOT_ALLOWED_RESP) catch return; return; }
        var sum: i64 = 0;
        if (req.query) |q| sum = parseQuerySum(q);
        var nb: [32]u8 = undefined;
        writeTextResponse(out, writeI64(&nb, sum));
        return;
    }

    if (path.len == 5 and mem.eql(u8, path, "/json")) {
        if (!isGet(req.method)) { out.appendSlice(METHOD_NOT_ALLOWED_RESP) catch return; return; }
        writeRawResponse(out, dataset_json_resp);
        return;
    }

    if (path.len == 7 and mem.eql(u8, path, "/upload")) {
        if (!isGetOrPost(req.method)) { out.appendSlice(METHOD_NOT_ALLOWED_RESP) catch return; return; }
        if (req.body) |body| {
            var nb: [32]u8 = undefined;
            writeTextResponse(out, writeUsize(&nb, body.len));
        } else {
            writeTextResponse(out, "0");
        }
        return;
    }

    if (mem.startsWith(u8, path, "/static/") and path.len > 8) {
        if (!isGet(req.method)) { out.appendSlice(METHOD_NOT_ALLOWED_RESP) catch return; return; }
        if (findStaticFile(path[8..])) |resp| {
            out.appendSlice(resp) catch return;
            return;
        }
    }

    out.appendSlice(NOT_FOUND_RESP) catch return;
}

fn handleBaseline(req: *const Request, out: *std.ArrayList(u8)) void {
    var sum: i64 = 0;
    if (req.query) |q| sum = parseQuerySum(q);
    if (mem.eql(u8, req.method, "POST")) {
        if (req.body) |body| {
            const trimmed = mem.trim(u8, body, " \t\r\n");
            sum += std.fmt.parseInt(i64, trimmed, 10) catch 0;
        }
    }
    var nb: [32]u8 = undefined;
    writeTextResponse(out, writeI64(&nb, sum));
}

fn writeTextResponse(out: *std.ArrayList(u8), body: []const u8) void {
    var cl_buf: [32]u8 = undefined;
    const cl_s = writeUsize(&cl_buf, body.len);
    out.appendSlice("HTTP/1.1 200 OK\r\n" ++ SERVER_HDR ++ CT_PLAIN ++ "Content-Length: ") catch return;
    out.appendSlice(cl_s) catch return;
    out.appendSlice("\r\n\r\n") catch return;
    out.appendSlice(body) catch return;
}

fn writeRawResponse(out: *std.ArrayList(u8), resp: []const u8) void {
    out.appendSlice(resp) catch return;
}

// ── Socket helpers ──────────────────────────────────────────────────

fn setSockOptInt(fd: i32, level: i32, optname: u32, val: c_int) void {
    const v = mem.toBytes(val);
    posix.setsockopt(fd, level, optname, &v) catch {};
}

// ── Worker ──────────────────────────────────────────────────────────

fn workerLoop(_: usize) void {
    const alloc = std.heap.c_allocator;

    // Create listening socket
    const sock: i32 = @intCast(posix.socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0) catch return);
    defer posix.close(sock);

    setSockOptInt(sock, SOL_SOCKET, SO_REUSEPORT, 1);
    setSockOptInt(sock, SOL_SOCKET, SO_REUSEADDR, 1);
    setSockOptInt(sock, IPPROTO_TCP, TCP_NODELAY, 1);

    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, PORT);
    posix.bind(sock, &address.any, address.getOsSockLen()) catch return;
    posix.listen(sock, 4096) catch return;

    // Epoll
    const epfd = posix.epoll_create1(linux.EPOLL.CLOEXEC) catch return;
    defer posix.close(epfd);

    var listen_ev = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .fd = sock } };
    posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, sock, &listen_ev) catch return;

    var conns: [MAX_CONNS]?*ConnState = undefined;
    @memset(&conns, null);
    var events: [MAX_EVENTS]linux.epoll_event = undefined;

    while (true) {
        const n = posix.epoll_wait(epfd, &events, -1);
        for (events[0..n]) |ev| {
            const fd = ev.data.fd;

            if (fd == sock) {
                // Accept loop
                while (true) {
                    var caddr: posix.sockaddr = undefined;
                    var clen: posix.socklen_t = @sizeOf(posix.sockaddr);
                    const cfd = posix.accept(sock, &caddr, &clen, SOCK_NONBLOCK) catch break;
                    const cfd_i: i32 = @intCast(cfd);
                    setSockOptInt(cfd_i, IPPROTO_TCP, TCP_NODELAY, 1);

                    const uidx: usize = @intCast(cfd);
                    if (uidx >= MAX_CONNS) { posix.close(cfd); continue; }

                    const st = alloc.create(ConnState) catch { posix.close(cfd); continue; };
                    st.* = ConnState.init(alloc);
                    conns[uidx] = st;

                    var cev = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.ET, .data = .{ .fd = cfd_i } };
                    posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, cfd_i, &cev) catch {
                        st.deinit();
                        alloc.destroy(st);
                        conns[uidx] = null;
                        posix.close(cfd);
                    };
                }
                continue;
            }

            const uidx: usize = @intCast(fd);
            if (uidx >= MAX_CONNS) continue;
            const st = conns[uidx] orelse continue;

            if (ev.events & linux.EPOLL.IN != 0) {
                var should_close = false;
                // Read as much as possible (edge-triggered)
                if (st.overflow_buf != null) {
                    // Reading into overflow buffer
                    while (true) {
                        st.ensureOverflow(BUF_SIZE) catch { should_close = true; break; };
                        const buf = st.overflow_buf.?;
                        const n_read = posix.read(fd, buf[st.overflow_len..]) catch { should_close = true; break; };
                        if (n_read == 0) { should_close = true; break; }
                        st.overflow_len += n_read;
                    }
                } else {
                    while (st.read_len < BUF_SIZE) {
                        const n_read = posix.read(fd, st.read_buf[st.read_len..]) catch { should_close = true; break; };
                        if (n_read == 0) { should_close = true; break; }
                        st.read_len += n_read;
                    }
                    // If fixed buffer is full but request incomplete, promote to overflow
                    if (st.read_len >= BUF_SIZE) {
                        if (parseRequest(st.read_buf[0..st.read_len]) == null) {
                            st.ensureOverflow(BUF_SIZE) catch { should_close = true; };
                            // Continue reading into overflow
                            if (!should_close) {
                                while (true) {
                                    st.ensureOverflow(BUF_SIZE) catch { should_close = true; break; };
                                    const buf = st.overflow_buf.?;
                                    const n_read = posix.read(fd, buf[st.overflow_len..]) catch { should_close = true; break; };
                                    if (n_read == 0) { should_close = true; break; }
                                    st.overflow_len += n_read;
                                }
                            }
                        }
                    }
                }

                // Parse & handle pipelined requests
                const data = st.readableData();
                var off: usize = 0;
                while (off < data.len) {
                    const req = parseRequest(data[off..]) orelse break;
                    handleRequest(&req, &st.write_list);
                    off += req.total_len;
                }
                if (off > 0) {
                    st.consume(off);
                }

                // Flush writes
                if (st.write_list.items.len > st.write_off) {
                    const written = posix.write(fd, st.write_list.items[st.write_off..]) catch blk: { should_close = true; break :blk 0; };
                    st.write_off += written;
                    if (st.write_off >= st.write_list.items.len) {
                        st.write_list.clearRetainingCapacity();
                        st.write_off = 0;
                    } else {
                        var mev = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.OUT | linux.EPOLL.ET, .data = .{ .fd = fd } };
                        posix.epoll_ctl(epfd, linux.EPOLL.CTL_MOD, fd, &mev) catch {};
                    }
                }

                if (should_close and st.write_off >= st.write_list.items.len) {
                    closeConn(alloc, &conns, epfd, fd, uidx);
                    continue;
                }
            }

            if (ev.events & linux.EPOLL.OUT != 0) {
                if (conns[uidx]) |s| {
                    if (s.write_list.items.len > s.write_off) {
                        const w = posix.write(fd, s.write_list.items[s.write_off..]) catch {
                            closeConn(alloc, &conns, epfd, fd, uidx);
                            continue;
                        };
                        s.write_off += w;
                    }
                    if (s.write_off >= s.write_list.items.len) {
                        s.write_list.clearRetainingCapacity();
                        s.write_off = 0;
                        var mev = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.ET, .data = .{ .fd = fd } };
                        posix.epoll_ctl(epfd, linux.EPOLL.CTL_MOD, fd, &mev) catch {};
                    }
                }
            }

            if (ev.events & (linux.EPOLL.ERR | linux.EPOLL.HUP) != 0) {
                closeConn(alloc, &conns, epfd, fd, uidx);
            }
        }
    }
}

fn closeConn(alloc: std.mem.Allocator, conns: *[MAX_CONNS]?*ConnState, epfd: i32, fd: i32, uidx: usize) void {
    posix.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, fd, null) catch {};
    if (conns[uidx]) |s| { s.deinit(); alloc.destroy(s); conns[uidx] = null; }
    posix.close(fd);
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

    // Build pre-serialized HTTP response
    var json_buf = std.ArrayList(u8).init(alloc);
    json_buf.appendSlice("{\"items\":[") catch return "";

    for (items, 0..) |item, idx| {
        if (idx > 0) json_buf.append(',') catch {};
        const obj = item.object;
        const price = switch (obj.get("price").?) { .float => |f| f, .integer => |i| @as(f64, @floatFromInt(i)), else => 0.0 };
        const quantity = switch (obj.get("quantity").?) { .integer => |i| i, else => 0 };
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
    json_buf.appendSlice(writeUsize(&count_buf, items.len)) catch {};
    json_buf.append('}') catch {};

    // Build full HTTP response
    var cl_buf: [32]u8 = undefined;
    out.appendSlice("HTTP/1.1 200 OK\r\n" ++ SERVER_HDR ++ CT_JSON ++ "Content-Length: ") catch return "";
    out.appendSlice(writeUsize(&cl_buf, json_buf.items.len)) catch return "";
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
        resp.appendSlice("HTTP/1.1 200 OK\r\n" ++ SERVER_HDR ++ "Content-Type: ") catch continue;
        resp.appendSlice(ct) catch continue;
        resp.appendSlice("\r\nContent-Length: ") catch continue;
        resp.appendSlice(writeUsize(&cl_buf, data.len)) catch continue;
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
    dataset_json_resp = loadDataset("/data/dataset.json");
    loadStaticFiles();

    const n_threads = @max(Thread.getCpuCount() catch 1, 1);
    var threads = std.ArrayList(Thread).init(std.heap.c_allocator);
    for (1..n_threads) |i| {
        const t = try Thread.spawn(.{}, workerLoop, .{i});
        try threads.append(t);
    }

    workerLoop(0);
}
