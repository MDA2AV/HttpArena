//! HttpArena: zix-http3
//!
//! zix HTTP/3 entry point on the zix.Http3 engine (pure-Zig QUIC over zix.Udp, no std.http).
//!
//! Intent: exercise zix.Http3 against the HttpArena H/3 category (baseline-h3, static-h3). One
//! process binds two listeners on port 8443:
//! - QUIC h3 on UDP under the .URING dispatch model (v1 single-worker recv with internal
//!   connection-id demux). This is the benchmark target (h2load --alpn-list=h3).
//! - h2 over TLS 1.3 on TCP, the readiness-probe listener: the harness probes h3 liveness with a
//!   plain curl over HTTPS on 8443, which speaks TCP, not QUIC. Without a TCP listener the probe
//!   never passes. The same dual-port pattern the existing h3 frameworks use.
//!
//! Certificate: a self-signed Ed25519 cert, baked into the image at /etc/zix-h3. QUIC mandates
//! TLS 1.3, and the v1 handshake flight is a single packet an RSA-2048 cert would overflow, so a
//! small key is required. Nothing in the harness verifies the certificate.
//!
//! Endpoints:
//! - GET /baseline2?a=..&b=.. : sum the query values, text/plain.
//! - GET /static/{file}       : serve a file from /data/static, content type by extension. Served
//!   identity (the h3 response has no content-encoding field, so no br/gzip negotiation).

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

const TLS_PORT: u16 = 8443;
// Both listeners bind dual-stack IPv6 ("::"): the TCP h2 listener and the zix.Udp / QUIC h3 listener
// (dual-stack, so "::" also accepts IPv4 as IPv4-mapped) serve clients reaching the host over either
// family.
const LISTEN_IP: []const u8 = "::";
const KERNEL_BACKLOG: u31 = 16 * 1024;
const H3_DISPATCH: zix.Http3.DispatchModel = .URING;

// Ed25519 cert / key, baked into the image. Overridable via env so the same binary runs locally.
const TLS_CERT_DEFAULT: []const u8 = "/etc/zix-h3/server.crt";
const TLS_KEY_DEFAULT: []const u8 = "/etc/zix-h3/server.key";

// Max DATA frame payload on the h2 readiness listener (the HTTP/2 default SETTINGS_MAX_FRAME_SIZE).
const MAX_DATA_CHUNK: usize = 16 * 1024;

// Static directory, overridable via ARENA_DATA (default /data, the container mount point).
var g_static_base: []const u8 = "/data/static/";
var g_static_base_buf: [256]u8 = undefined;

// Per-worker scratch for the baseline sum body.
threadlocal var h3_sum_buf: [32]u8 = undefined;

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

fn contentType(rel: []const u8) []const u8 {
    if (std.mem.endsWith(u8, rel, ".css")) return "text/css";
    if (std.mem.endsWith(u8, rel, ".js")) return "application/javascript";
    if (std.mem.endsWith(u8, rel, ".json")) return "application/json";
    if (std.mem.endsWith(u8, rel, ".html")) return "text/html";
    if (std.mem.endsWith(u8, rel, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, rel, ".woff2")) return "font/woff2";
    if (std.mem.endsWith(u8, rel, ".webp")) return "image/webp";

    return "application/octet-stream";
}

// --------------------------------------------------------- //
// Static cache, shared by both listeners: each fixture is read into a process-lifetime buffer once
// and reused. Append-only, readers scan 0..count lock-free (count published with release after the
// slot is written), the spinlock only serializes the rare insert.

const STATIC_NAME_MAX = 96;
const STATIC_CACHE_MAX = 64;

const StaticEntry = struct {
    name_len: u16,
    name_buf: [STATIC_NAME_MAX]u8,
    bytes: []const u8,
    content_type: []const u8,
    ok: bool,
};

var g_static_entries: [STATIC_CACHE_MAX]StaticEntry = undefined;
var g_static_count: usize = 0;
var g_static_lock: std.atomic.Value(bool) = .init(false);

fn staticLookup(rel: []const u8, count: usize) ?*const StaticEntry {
    for (g_static_entries[0..count]) |*e| {
        if (std.mem.eql(u8, e.name_buf[0..e.name_len], rel)) return e;
    }

    return null;
}

fn readStaticFile(rel: []const u8) ?[]const u8 {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ g_static_base, rel }) catch return null;
    if (path.len >= path_buf.len) return null;

    path_buf[path.len] = 0;

    const file_fd = std.posix.openatZ(std.posix.AT.FDCWD, @ptrCast(&path_buf), .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = std.posix.system.close(file_fd);

    var stx: std.os.linux.Statx = undefined;
    const stat_rc = std.os.linux.statx(file_fd, "", std.os.linux.AT.EMPTY_PATH, .{ .SIZE = true }, &stx);
    if (std.posix.errno(stat_rc) != .SUCCESS) return null;

    const size: usize = @intCast(stx.size);
    const buf = std.heap.smp_allocator.alloc(u8, size) catch return null;

    var read: usize = 0;
    while (read < size) {
        const n = std.posix.read(file_fd, buf[read..]) catch {
            std.heap.smp_allocator.free(buf);
            return null;
        };
        if (n == 0) break;
        read += n;
    }

    return buf[0..read];
}

fn staticInsert(rel: []const u8) ?*const StaticEntry {
    while (g_static_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
    defer g_static_lock.store(false, .release);

    const count = @atomicLoad(usize, &g_static_count, .acquire);
    if (staticLookup(rel, count)) |e| return e;
    if (count == STATIC_CACHE_MAX) return null;

    const e = &g_static_entries[count];
    e.name_len = @intCast(rel.len);
    @memcpy(e.name_buf[0..rel.len], rel);
    if (readStaticFile(rel)) |bytes| {
        e.bytes = bytes;
        e.content_type = contentType(rel);
        e.ok = true;
    } else {
        e.bytes = &.{};
        e.content_type = "text/plain";
        e.ok = false;
    }

    @atomicStore(usize, &g_static_count, count + 1, .release);

    return e;
}

/// Resolve a `/static/<file>` request path to a cached entry, or null for a bad / missing path.
fn staticResolve(raw_path: []const u8) ?*const StaticEntry {
    const path = if (std.mem.indexOfScalar(u8, raw_path, '?')) |q| raw_path[0..q] else raw_path;
    if (!std.mem.startsWith(u8, path, "/static/")) return null;

    const rel = path["/static/".len..];
    if (rel.len == 0 or rel.len > STATIC_NAME_MAX or std.mem.indexOf(u8, rel, "..") != null or rel[0] == '/') return null;

    const count = @atomicLoad(usize, &g_static_count, .acquire);
    const entry = staticLookup(rel, count) orelse staticInsert(rel) orelse return null;
    if (!entry.ok) return null;

    return entry;
}

// --------------------------------------------------------- //
// HTTP/3 handlers (the benchmark path).

// GET /baseline2?a=..&b=.. : sum the query values, text/plain.
fn h3Baseline(req: *const zix.Http3.Request, res: *zix.Http3.Response) void {
    const query = if (std.mem.indexOfScalar(u8, req.path, '?')) |q| req.path[q + 1 ..] else "";
    const sum = sumQuery(query);

    const out = std.fmt.bufPrint(&h3_sum_buf, "{d}", .{sum}) catch "0";
    res.send(out);
}

// GET /static/{file} : serve a cached file from /data/static, content type by extension. Served
// identity (the h3 response carries no content-encoding, so no br/gzip negotiation).
fn h3Static(req: *const zix.Http3.Request, res: *zix.Http3.Response) void {
    const entry = staticResolve(req.path) orelse {
        res.setStatus(404);
        res.send("Not Found");
        return;
    };

    res.content_type = entry.content_type;
    res.send(entry.bytes);
}

const H3Routes = zix.Http3.Router(&[_]zix.Http3.Route{
    .{ .path = "/baseline2", .handler = h3Baseline },
    .{ .path = "/static", .handler = h3Static, .kind = .PREFIX },
});

// --------------------------------------------------------- //
// HTTP/2 handlers (the TCP readiness-probe path on the same port).

fn pathFromHeaders(headers: []const zix.Http2.Header) []const u8 {
    for (headers) |h| {
        if (std.mem.eql(u8, h.name, ":path")) return h.value;
    }

    return "/";
}

fn h2Baseline(_: []const u8, headers: []const zix.Http2.Header, _: []const u8, fd: std.posix.fd_t, sid: u31) void {
    const path = pathFromHeaders(headers);
    const query = if (std.mem.indexOfScalar(u8, path, '?')) |q| path[q + 1 ..] else "";
    const sum = sumQuery(query);

    var body_buf: [32]u8 = undefined;
    const out = std.fmt.bufPrint(&body_buf, "{d}", .{sum}) catch return;

    zix.Http2.sendResponse(fd, sid, 200, "text/plain", out) catch {};
}

fn h2Static(_: []const u8, headers: []const zix.Http2.Header, _: []const u8, fd: std.posix.fd_t, sid: u31) void {
    const entry = staticResolve(pathFromHeaders(headers)) orelse {
        zix.Http2.sendResponse(fd, sid, 404, "text/plain", "Not Found") catch {};
        return;
    };

    sendH2File(fd, sid, entry.content_type, entry.bytes);
}

/// Send a 200 whose body is framed across DATA frames of at most MAX_DATA_CHUNK bytes.
fn sendH2File(fd: std.posix.fd_t, sid: u31, content_type: []const u8, bytes: []const u8) void {
    var hdr_buf: [256]u8 = undefined;
    var enc = zix.Http2.HpackEncoder.init(&hdr_buf);
    enc.writeHeader(":status", "200") catch return;
    enc.writeHeader("content-type", content_type) catch return;

    var cl_buf: [20]u8 = undefined;
    const cl_s = std.fmt.bufPrint(&cl_buf, "{d}", .{bytes.len}) catch return;
    enc.writeHeader("content-length", cl_s) catch return;
    const hblock = enc.encoded();

    const headers_only = bytes.len == 0;
    zix.Http2.writeFrameHeader(fd, .{
        .length = @intCast(hblock.len),
        .frame_type = zix.Http2.FRAME_TYPE_HEADERS,
        .flags = if (headers_only) zix.Http2.FLAG_END_HEADERS | zix.Http2.FLAG_END_STREAM else zix.Http2.FLAG_END_HEADERS,
        .stream_id = sid,
    }) catch return;
    zix.Http2.fdWriteAll(fd, hblock) catch return;

    if (headers_only) return;

    var off: usize = 0;
    while (off < bytes.len) {
        const chunk = @min(bytes.len - off, MAX_DATA_CHUNK);
        const last = off + chunk == bytes.len;

        zix.Http2.writeFrameHeader(fd, .{
            .length = @intCast(chunk),
            .frame_type = zix.Http2.FRAME_TYPE_DATA,
            .flags = if (last) zix.Http2.FLAG_END_STREAM else 0,
            .stream_id = sid,
        }) catch return;
        zix.Http2.fdWriteAll(fd, bytes[off..][0..chunk]) catch return;

        off += chunk;
    }
}

const H2_ROUTES = &[_]zix.Http2.Route{
    .{ .path = "/baseline2", .handler = h2Baseline },
    .{ .path = "/static", .handler = h2Static, .kind = .PREFIX },
};

// h2-over-TLS readiness listener: the per-core tls_mux terminates TLS 1.3 (ALPN h2) on TLS_PORT over
// TCP. A missing or unreadable cert degrades gracefully: this thread returns and only the QUIC
// listener serves.
fn h2TlsServer(io: std.Io, tls: *zix.Tls.Context) void {
    var server = zix.Http2.Server.init(H2_ROUTES, .{
        .io = io,
        .ip = LISTEN_IP,
        .port = TLS_PORT,
        .tls = tls,
        .dispatch_model = .URING,
        .kernel_backlog = KERNEL_BACKLOG,
    }) catch return;
    defer server.deinit();

    server.run() catch {};
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    // Elevate scheduling priority (setpriority -19). Fails silently without CAP_SYS_NICE.
    _ = std.os.linux.syscall3(.setpriority, 0, 0, @as(usize, @bitCast(@as(isize, -19))));

    const data_dir = process.environ_map.get("ARENA_DATA") orelse "/data";
    g_static_base = std.fmt.bufPrint(&g_static_base_buf, "{s}/static/", .{data_dir}) catch "/data/static/";

    const cert_path = process.environ_map.get("ARENA_TLS_CERT") orelse TLS_CERT_DEFAULT;
    const key_path = process.environ_map.get("ARENA_TLS_KEY") orelse TLS_KEY_DEFAULT;

    // h2 over TLS 1.3 on TLS_PORT (TCP), the readiness-probe listener. Uses the same Ed25519 cert as
    // the QUIC listener. A missing cert leaves the TCP port without a listener, the QUIC listener
    // still runs.
    var h2_tls: ?zix.Tls.Context = zix.Tls.Context.init(std.heap.smp_allocator, process.io, .{
        .cert_path = cert_path,
        .key_path = key_path,
        .alpn = &.{.H2},
        .min_version = .TLS_1_3,
    }) catch null;

    if (h2_tls) |*tls| {
        _ = std.Thread.spawn(.{}, h2TlsServer, .{ process.io, tls }) catch {};
    }

    // h3 over QUIC on TLS_PORT (UDP), the benchmark listener, under the .URING dispatch model. QUIC
    // mandates TLS 1.3 and emits the h3 ALPN itself, so the context takes neither .alpn nor
    // .min_version.
    var h3_tls = try zix.Tls.Context.init(std.heap.smp_allocator, process.io, .{
        .cert_path = cert_path,
        .key_path = key_path,
    });
    defer h3_tls.deinit();

    const Server = zix.Http3.Http3(H3Routes.dispatch);
    var server = try Server.init(.{
        .io = process.io,
        .allocator = std.heap.smp_allocator,
        .ip = LISTEN_IP,
        .port = TLS_PORT,
        .dispatch_model = H3_DISPATCH,
        .tls = &h3_tls,
        .gso_enabled = true,
    });
    defer server.deinit();

    try server.run();
}
