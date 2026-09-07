// HttpArena baseline server on libxev's io_uring event loop.
//
// One forked worker per available CPU, each with its own xev.Loop and SO_REUSEPORT listener.
// Per connection: accept -> read (accumulate) -> parse with picohttpparser (fragmentation- and
// chunked-safe) -> sum -> write -> keep-alive or close. HTTP parsing is delegated to picohttpparser
// via C interop; this file is the libxev glue plus the /baseline11 arithmetic.

const std = @import("std");
const xev = @import("xev");
const posix = std.posix;
const linux = std.os.linux;

const c = @cImport({
    @cInclude("picohttpparser.h");
});

const REQ_CAP: usize = 16384;
const RESP_CAP: usize = 8192;
const SCRATCH_CAP: usize = 4096;

const alloc = std.heap.c_allocator;

const Server = struct {
    loop: *xev.Loop,
    listener: xev.TCP,
    accept_c: xev.Completion = undefined,
};

const Conn = struct {
    server: *Server,
    socket: xev.TCP,
    read_c: xev.Completion = undefined,
    write_c: xev.Completion = undefined,
    buf: [REQ_CAP]u8 = undefined,
    have: usize = 0,
    resp: [RESP_CAP]u8 = undefined,
    resp_len: usize = 0,
    scratch: [SCRATCH_CAP]u8 = undefined,
    want_close: bool = false,
};

fn destroyConn(conn: *Conn) void {
    alloc.destroy(conn);
}

// ── HTTP arithmetic ──────────────────────────────────────────────────────────────────────

fn sumQuery(q: []const u8) i64 {
    var sum: i64 = 0;
    var i: usize = 0;
    while (i < q.len) {
        while (i < q.len and q[i] != '=') : (i += 1) {}
        if (i >= q.len) break;
        i += 1;
        var v: i64 = 0;
        var any = false;
        while (i < q.len and q[i] != '&') : (i += 1) {
            if (q[i] >= '0' and q[i] <= '9') {
                v = v * 10 + @as(i64, q[i] - '0');
                any = true;
            }
        }
        if (any) sum += v;
        if (i < q.len and q[i] == '&') i += 1;
    }
    return sum;
}

fn bodyInt(b: []const u8) i64 {
    var v: i64 = 0;
    for (b) |ch| {
        if (ch < '0' or ch > '9') break;
        v = v * 10 + @as(i64, ch - '0');
    }
    return v;
}

fn fieldEqCI(name: []const u8, target: []const u8) bool {
    if (name.len != target.len) return false;
    for (name, target) |a, t| {
        if (std.ascii.toLower(a) != t) return false;
    }
    return true;
}

fn valueHasClose(v: []const u8) bool {
    if (v.len < 5) return false;
    var i: usize = 0;
    while (i + 5 <= v.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(v[i .. i + 5], "close")) return true;
    }
    return false;
}

fn putUint(dst: []u8, value: u64) usize {
    var tmp: [20]u8 = undefined;
    var t: usize = 0;
    var u = value;
    while (true) {
        tmp[t] = @intCast('0' + (u % 10));
        t += 1;
        u /= 10;
        if (u == 0) break;
    }
    var i: usize = 0;
    while (i < t) : (i += 1) dst[i] = tmp[t - 1 - i];
    return t;
}

// Append one HTTP/1.1 response for `sum` to resp; returns bytes written.
fn writeResponse(dst: []u8, sum: i64, keep_alive: bool) usize {
    var p: usize = 0;
    const status = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ";
    @memcpy(dst[p .. p + status.len], status);
    p += status.len;

    // body is the decimal sum
    var body: [24]u8 = undefined;
    const uval: u64 = if (sum < 0) 0 else @intCast(sum);
    const blen = putUint(&body, uval);

    p += putUint(dst[p..], blen);
    @memcpy(dst[p .. p + 2], "\r\n");
    p += 2;

    const conn_h = if (keep_alive) "Connection: keep-alive\r\n\r\n" else "Connection: close\r\n\r\n";
    @memcpy(dst[p .. p + conn_h.len], conn_h);
    p += conn_h.len;

    @memcpy(dst[p .. p + blen], body[0..blen]);
    p += blen;
    return p;
}

// Result of trying to consume one request from buf.
const Parsed = union(enum) {
    incomplete, // need more bytes
    bad, // malformed -> close
    ok: struct { consumed: usize, sum: i64, keep_alive: bool },
};

fn parseOne(conn: *Conn, buf: []u8) Parsed {
    var method: [*c]const u8 = undefined;
    var method_len: usize = 0;
    var path: [*c]const u8 = undefined;
    var path_len: usize = 0;
    var minor: c_int = 0;
    var headers: [32]c.phr_header = undefined;
    var num: usize = 32;

    const pret = c.phr_parse_request(buf.ptr, buf.len, &method, &method_len, &path, &path_len, &minor, &headers, &num, 0);
    if (pret == -2) return .incomplete;
    if (pret < 0) return .bad;
    const header_len: usize = @intCast(pret);

    const target = path[0..path_len];
    const qmark = std.mem.indexOfScalar(u8, target, '?');
    const query: []const u8 = if (qmark) |m| target[m + 1 ..] else "";

    // scan headers for content-length, transfer-encoding, connection
    var content_length: usize = 0;
    var chunked = false;
    var keep_alive = minor >= 1;
    var i: usize = 0;
    while (i < num) : (i += 1) {
        const hn = headers[i].name[0..headers[i].name_len];
        const hv = headers[i].value[0..headers[i].value_len];
        if (fieldEqCI(hn, "content-length")) {
            content_length = @intCast(bodyInt(hv));
        } else if (fieldEqCI(hn, "transfer-encoding")) {
            if (valueHasClose(hv) == false and (std.ascii.indexOfIgnoreCase(hv, "chunked") != null)) chunked = true;
        } else if (fieldEqCI(hn, "connection")) {
            if (valueHasClose(hv)) keep_alive = false else if (std.ascii.indexOfIgnoreCase(hv, "keep-alive") != null) keep_alive = true;
        }
    }

    var sum: i64 = sumQuery(query);
    var consumed: usize = header_len;

    if (chunked) {
        // decode the chunked body from a scratch copy so buf stays intact if incomplete
        const raw = buf[header_len..];
        if (raw.len > conn.scratch.len) return .bad;
        @memcpy(conn.scratch[0..raw.len], raw);
        var dec: c.phr_chunked_decoder = std.mem.zeroes(c.phr_chunked_decoder);
        dec.consume_trailer = 1;
        var sz: usize = raw.len;
        const dret = c.phr_decode_chunked(&dec, &conn.scratch, &sz);
        if (dret == -2) return .incomplete;
        if (dret < 0) return .bad;
        // sz = decoded length; dret = trailing bytes after the chunked data
        sum += bodyInt(conn.scratch[0..sz]);
        const trailing: usize = @intCast(dret);
        consumed = header_len + (raw.len - trailing);
    } else {
        const total = header_len + content_length;
        if (total > buf.len) {
            if (total > REQ_CAP) return .bad;
            return .incomplete;
        }
        if (buf.len < total) return .incomplete;
        sum += bodyInt(buf[header_len..total]);
        consumed = total;
    }

    return .{ .ok = .{ .consumed = consumed, .sum = sum, .keep_alive = keep_alive } };
}

// Process as many complete requests as are buffered; fill conn.resp; shift leftover to front.
// Returns true if the connection should keep going, false on malformed (caller closes).
fn process(conn: *Conn) bool {
    conn.resp_len = 0;
    conn.want_close = false;
    var off: usize = 0;
    while (off < conn.have) {
        switch (parseOne(conn, conn.buf[off..conn.have])) {
            .incomplete => break,
            .bad => return false,
            .ok => |r| {
                if (conn.resp_len + 256 + 24 > conn.resp.len) break; // response buffer guard
                conn.resp_len += writeResponse(conn.resp[conn.resp_len..], r.sum, r.keep_alive);
                off += r.consumed;
                if (!r.keep_alive) {
                    conn.want_close = true;
                    break;
                }
            },
        }
    }
    // shift the unconsumed tail to the front
    const leftover = conn.have - off;
    if (leftover > 0 and off > 0) std.mem.copyForwards(u8, conn.buf[0..leftover], conn.buf[off..conn.have]);
    conn.have = leftover;
    return true;
}

// ── libxev callbacks ─────────────────────────────────────────────────────────────────────

fn closeCb(_: ?*Conn, _: *xev.Loop, _: *xev.Completion, _: xev.TCP, _: xev.CloseError!void) xev.CallbackAction {
    return .disarm;
}

fn finish(conn: *Conn, l: *xev.Loop) xev.CallbackAction {
    conn.socket.close(l, &conn.read_c, Conn, conn, struct {
        fn cb(c_: ?*Conn, _: *xev.Loop, _: *xev.Completion, _: xev.TCP, _: xev.CloseError!void) xev.CallbackAction {
            destroyConn(c_.?);
            return .disarm;
        }
    }.cb);
    return .disarm;
}

fn armRead(conn: *Conn, l: *xev.Loop) void {
    conn.socket.read(l, &conn.read_c, .{ .slice = conn.buf[conn.have..] }, Conn, conn, readCb);
}

fn readCb(
    conn_: ?*Conn,
    l: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    _: xev.ReadBuffer,
    r: xev.ReadError!usize,
) xev.CallbackAction {
    const conn = conn_.?;
    const n = r catch {
        return finish(conn, l);
    };
    if (n == 0) return finish(conn, l);
    conn.have += n;

    if (!process(conn)) return finish(conn, l);

    if (conn.resp_len > 0) {
        conn.socket.write(l, &conn.write_c, .{ .slice = conn.resp[0..conn.resp_len] }, Conn, conn, writeCb);
        return .disarm;
    }
    // incomplete request: read more
    if (conn.have >= conn.buf.len) return finish(conn, l);
    armRead(conn, l);
    return .disarm;
}

fn writeCb(
    conn_: ?*Conn,
    l: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    _: xev.WriteBuffer,
    r: xev.WriteError!usize,
) xev.CallbackAction {
    const conn = conn_.?;
    _ = r catch {
        return finish(conn, l);
    };
    if (conn.want_close) return finish(conn, l);
    armRead(conn, l);
    return .disarm;
}

fn acceptCb(
    server_: ?*Server,
    l: *xev.Loop,
    _: *xev.Completion,
    r: xev.AcceptError!xev.TCP,
) xev.CallbackAction {
    const server = server_.?;
    const sock = r catch {
        return .rearm;
    };
    const conn = alloc.create(Conn) catch {
        return .rearm;
    };
    conn.* = .{ .server = server, .socket = sock };
    conn.socket.read(l, &conn.read_c, .{ .slice = conn.buf[0..] }, Conn, conn, readCb);
    return .rearm;
}

// ── workers ──────────────────────────────────────────────────────────────────────────────

fn serve(port: u16) !void {
    var loop = try xev.Loop.init(.{ .entries = 4096 });
    defer loop.deinit();

    const addr = try std.Io.net.IpAddress.parse("0.0.0.0", port);
    var listener = try xev.TCP.init(addr);

    const one: c_int = 1;
    try posix.setsockopt(listener.fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&one));
    try posix.setsockopt(listener.fd, posix.SOL.SOCKET, posix.SO.REUSEPORT, std.mem.asBytes(&one));
    try posix.setsockopt(listener.fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, std.mem.asBytes(&one));

    try listener.bind(addr);
    try listener.listen(1024);

    var server = Server{ .loop = &loop, .listener = listener };
    listener.accept(&loop, &server.accept_c, Server, &server, acceptCb);

    try loop.run(.until_done);
}

fn cpuCount() usize {
    var set: linux.cpu_set_t = undefined;
    if (linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &set) == 0) {
        var n: usize = 0;
        for (set) |word| n += @popCount(word);
        if (n > 0) return n;
    }
    return std.Thread.getCpuCount() catch 1;
}

pub fn main() !void {
    posix.sigaction(posix.SIG.PIPE, &.{ .handler = .{ .handler = posix.SIG.IGN }, .mask = posix.sigemptyset(), .flags = 0 }, null);

    const workers = cpuCount();
    var i: usize = 1;
    while (i < workers) : (i += 1) {
        const pid = std.c.fork();
        if (pid == 0) break; // child
    }
    try serve(8080);
}
