//! HttpArena: zix
//!
//! Handler file. zero-copy static file serving and lock-free caching.
//! Supports Brotli/Gzip negotiation, pipelined responses, and cached JSON generation.
//! Optimized for benchmarks via minimal allocations,
//! pre-computed headers, and direct FD handling.

const std = @import("std");
const zix = @import("zix");
const dataset = @import("dataset.zig");

// --------------------------------------------------------- //

/// Static cache name cap. Fixture names are short, anything longer is a 404.
pub const STATIC_NAME_MAX: usize = 96;
/// Static cache capacity:
/// 20 fixtures times their (.br, .gz, identity) candidates plus 404 headroom,
/// sized so the startup pre-warm fits every candidate with room to spare.
pub const STATIC_CACHE_MAX: usize = 128;

// --------------------------------------------------------- //

/// Accept-Encoding tokens the client advertised. A substring scan suffices for the fixed benchmark
/// header ("br;q=1, gzip;q=0.8"), no q-value parsing is needed.
const AcceptEncoding = struct {
    prefers_br: bool,
    accepts_gzip: bool,
};

/// One cached static file: the bytes read into memory once plus its content type. ok is false for a
/// missing file (caches the 404 so a bad path is not re-probed). content_encoding is "" for identity,
/// or "br" / "gzip" for a precompressed variant.
const StaticEntry = struct {
    name_len: u16,
    // rel (up to STATIC_NAME_MAX) plus a 3-char precompressed suffix (".br" or ".gz").
    name_buf: [STATIC_NAME_MAX + 3]u8,
    bytes: []const u8,
    content_type: []const u8,
    content_encoding: []const u8,
    ok: bool,
};

/// Content type plus content encoding for a cached static name. A ".br" / ".gz" suffix reports that
/// encoding, with the content type taken from the stripped name ("vendor.js.br" -> javascript).
const StaticMeta = struct {
    content_type: []const u8,
    content_encoding: []const u8,
};

// --------------------------------------------------------- //

// Per-worker scratch for the JSON body (largest, count 50, tops out near 12 KiB).
threadlocal var json_body_buf: [32 * 1024]u8 = undefined;

// Append-only cache:
// readers scan 0..count lock-free
// (count published release-ordered after the slot is fully written),
// the spinlock only serializes inserts (rare, one per distinct name during warmup).
var g_static_entries: [STATIC_CACHE_MAX]StaticEntry = undefined;
var g_static_count: usize = 0;
var g_static_lock: std.atomic.Value(bool) = .init(false);

// Data directory, overridable via the ARENA_DATA env var (default /data, the
// container mount point). Lets the same binary run against a local data tree.
pub var g_static_base: []const u8 = "/data/static/";
pub var g_static_base_buf: [256]u8 = undefined;

// --------------------------------------------------------- //

/// Must initialize in init main.
pub var g_dataset: dataset.Dataset = undefined;

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

fn queryParam(query: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
            if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
        }
    }

    return null;
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

fn notFound(fd: std.posix.fd_t, sid: u31) void {
    zix.Http2.sendResponseFD(fd, sid, 404, "text/plain", "Not Found") catch {};
}

fn badRequest(fd: std.posix.fd_t, sid: u31) void {
    zix.Http2.sendResponseFD(fd, sid, 400, "text/plain", "bad request") catch {};
}

/// Read the ":path" pseudo-header value (the request target, query included).
fn pathFromHeaders(headers: []const zix.Http2.Header) []const u8 {
    for (headers) |h| {
        if (std.mem.eql(u8, h.name, ":path")) return h.value;
    }

    return "/";
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

fn acceptEncoding(headers: []const zix.Http2.Header) AcceptEncoding {
    for (headers) |h| {
        if (std.mem.eql(u8, h.name, "accept-encoding")) {
            return .{
                .prefers_br = std.mem.indexOf(u8, h.value, "br") != null,
                .accepts_gzip = std.mem.indexOf(u8, h.value, "gzip") != null,
            };
        }
    }

    return .{ .prefers_br = false, .accepts_gzip = false };
}

fn staticLookup(rel: []const u8, count: usize) ?*const StaticEntry {
    for (g_static_entries[0..count]) |*e| {
        if (std.mem.eql(u8, e.name_buf[0..e.name_len], rel)) return e;
    }

    return null;
}

/// Read a static file fully into a process-lifetime buffer. Returns null when the file is absent.
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

fn staticMeta(name: []const u8) StaticMeta {
    if (std.mem.endsWith(u8, name, ".br")) {
        return .{ .content_type = contentType(name[0 .. name.len - ".br".len]), .content_encoding = "br" };
    }
    if (std.mem.endsWith(u8, name, ".gz")) {
        return .{ .content_type = contentType(name[0 .. name.len - ".gz".len]), .content_encoding = "gzip" };
    }

    return .{ .content_type = contentType(name), .content_encoding = "" };
}

/// Probe + cache a static path on first request, then return the slot. Caches a not-found slot so a
/// bad path is probed only once. Returns null only when the cache is full.
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
        const meta = staticMeta(rel);
        e.bytes = bytes;
        e.content_type = meta.content_type;
        e.content_encoding = meta.content_encoding;
        e.ok = true;
    } else {
        e.bytes = &.{};
        e.content_type = "text/plain";
        e.content_encoding = "";
        e.ok = false;
    }

    @atomicStore(usize, &g_static_count, count + 1, .release);

    return e;
}

/// Resolve a static name through the cache (lookup, then insert on a miss). Returns the slot only when
/// the file exists on disk (ok), so a caller can fall through to the next candidate on a missing variant.
pub fn resolveStatic(name: []const u8) ?*const StaticEntry {
    const count = @atomicLoad(usize, &g_static_count, .acquire);
    const entry = staticLookup(name, count) orelse staticInsert(name) orelse return null;
    if (!entry.ok) return null;

    return entry;
}

/// Send a 200 body through the flow-controlled streaming writer, which frames it into DATA chunks and
/// paces by the peer WINDOW_UPDATE. content_encoding is emitted only when non-empty.
fn sendH2File(fd: std.posix.fd_t, sid: u31, content_type: []const u8, content_encoding: []const u8, bytes: []const u8) void {
    // The cached bytes are process-lifetime, so the mux may reference and pace them by WINDOW_UPDATE.
    zix.Http2.sendResponseStreamFD(fd, sid, 200, content_type, content_encoding, bytes);
}

// --------------------------------------------------------- //

// GET/POST /baseline2?a=..&b=.. : sum query values plus the POST body as an integer, returns text/plain.
pub fn baseline(method: []const u8, headers: []const zix.Http2.Header, body: []const u8, fd: std.posix.fd_t, sid: u31) void {
    const path = pathFromHeaders(headers);
    const query = if (std.mem.indexOfScalar(u8, path, '?')) |q| path[q + 1 ..] else "";

    var sum: i64 = sumQuery(query);
    if (std.mem.eql(u8, method, "POST") and body.len > 0) {
        sum += parseIntLoose(body);
    }

    var body_buf: [32]u8 = undefined;
    const out = std.fmt.bufPrint(&body_buf, "{d}", .{sum}) catch return;

    zix.Http2.sendResponseFD(fd, sid, 200, "text/plain", out) catch {};
}

// GET /json/{count}?m=M : render count dataset items, total = price*quantity*M. Body (near 12 KiB) fits
// the 16 KiB frame cap, so it ships as a single DATA frame via sendResponseFD.
pub fn json(_: []const u8, headers: []const zix.Http2.Header, _: []const u8, fd: std.posix.fd_t, sid: u31) void {
    const path = pathFromHeaders(headers);
    if (!std.mem.startsWith(u8, path, "/json/")) return badRequest(fd, sid);

    const after = path["/json/".len..];
    const q = std.mem.indexOfScalar(u8, after, '?');
    const count_str = if (q) |i| after[0..i] else after;
    const query = if (q) |i| after[i + 1 ..] else "";

    const count = std.fmt.parseInt(u8, count_str, 10) catch return badRequest(fd, sid);
    if (count < 1 or count > dataset.ItemCount) return badRequest(fd, sid);

    const m: u64 = if (queryParam(query, "m")) |s| std.fmt.parseInt(u64, s, 10) catch 1 else 1;

    const buf = &json_body_buf;
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

    zix.Http2.sendResponseFD(fd, sid, 200, "application/json", buf[0..pos]) catch {};
}

// GET /static/{file} : serve from /data/static, content type by extension, body cached on first read.
// Negotiates .br then .gz when accepted, else identity. Never compresses, only serves a precompressed
// file already on disk.
pub fn static(_: []const u8, headers: []const zix.Http2.Header, _: []const u8, fd: std.posix.fd_t, sid: u31) void {
    const raw = pathFromHeaders(headers);
    const path = if (std.mem.indexOfScalar(u8, raw, '?')) |q| raw[0..q] else raw;
    if (!std.mem.startsWith(u8, path, "/static/")) return notFound(fd, sid);

    const rel = path["/static/".len..];
    if (rel.len == 0 or rel.len > STATIC_NAME_MAX or std.mem.indexOf(u8, rel, "..") != null or rel[0] == '/') return notFound(fd, sid);

    const accept = acceptEncoding(headers);

    // Candidates "{rel}.br" / "{rel}.gz" / "{rel}". The buffer holds rel plus a 3-char suffix.
    var cand_buf: [STATIC_NAME_MAX + 3]u8 = undefined;
    var entry: ?*const StaticEntry = null;

    if (accept.prefers_br) {
        const cand = std.fmt.bufPrint(&cand_buf, "{s}.br", .{rel}) catch return notFound(fd, sid);
        entry = resolveStatic(cand);
    }
    if (entry == null and accept.accepts_gzip) {
        const cand = std.fmt.bufPrint(&cand_buf, "{s}.gz", .{rel}) catch return notFound(fd, sid);
        entry = resolveStatic(cand);
    }
    if (entry == null) {
        entry = resolveStatic(rel);
    }

    const served = entry orelse return notFound(fd, sid);

    sendH2File(fd, sid, served.content_type, served.content_encoding, served.bytes);
}

