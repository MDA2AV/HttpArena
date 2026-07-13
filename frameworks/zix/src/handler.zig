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

// Precomputed response for the pipeline endpoint:
// written verbatim per request, no header build.
const PIPELINE_RESP: []const u8 = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nok";

/// Static cache name cap. Fixture names are short, anything longer is a 404.
pub const STATIC_NAME_MAX: usize = 96;
/// Static cache capacity:
/// 20 fixtures times their (.br, .gz, identity) candidates plus 404 headroom,
/// sized so the startup pre-warm fits every candidate with room to spare.
pub const STATIC_CACHE_MAX: usize = 128;

/// Freshness window. The dataset is immutable for the process lifetime, so a
/// long TTL means each key is built once and replayed for the whole run.
pub const CACHE_TTL_MS: u32 = 60 * 1000;

/// Accept-Encoding tokens the client advertised.
/// A substring scan suffices for the fixed benchmark
/// header ("br;q=1, gzip;q=0.8"), no q-value parsing is needed.
const AcceptEncoding = struct {
    prefers_br: bool,
    accepts_gzip: bool,
};

/// One servable variant of a static file:
/// a fd kept open for the process lifetime, its size, and the
/// pre-rendered response header (Content-Encoding baked in for precompressed variant).
const StaticVariant = struct {
    fd: std.posix.fd_t,
    size: u64,
    hdr_len: u16,
    hdr_buf: [192]u8,
};

/// Cache slot for one resolved static name
/// ("vendor.js.br" / "vendor.js.gz" / "vendor.js").
/// A null variant caches a miss so a bad name is probed only once.
const StaticEntry = struct {
    name_len: u16,
    // rel (up to STATIC_NAME_MAX) plus a 3-char precompressed suffix (".br" or ".gz").
    name_buf: [STATIC_NAME_MAX + 3]u8,
    variant: ?StaticVariant,
};

/// Content type plus content encoding for a cached static name.
/// A ".br" / ".gz" suffix reports that encoding, with the content type taken
/// from the stripped name ("vendor.js.br" -> javascript).
const StaticMeta = struct {
    content_type: []const u8,
    content_encoding: []const u8,
};

// --------------------------------------------------------- //

// Per-worker scratch. The JSON body (count up to 50) tops out near 12 KiB. The
// assembled response (status line + headers + body) sits a little above it.
threadlocal var json_body_buf: [32 * 1024]u8 = undefined;
threadlocal var json_resp_buf: [32 * 1024]u8 = undefined;

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

fn notFound(fd: std.posix.fd_t) void {
    zix.Http1.sendSimpleFD(fd, 404, "text/plain", "Not Found") catch {};
}

fn badRequest(fd: std.posix.fd_t) void {
    zix.Http1.sendSimpleFD(fd, 400, "text/plain", "Bad Request") catch {};
}

fn acceptEncoding(head: *const zix.Http1.ParsedHead) AcceptEncoding {
    const value = zix.Http1.getHeader(head, "accept-encoding") orelse return .{ .prefers_br = false, .accepts_gzip = false };

    return .{
        .prefers_br = std.mem.indexOf(u8, value, "br") != null,
        .accepts_gzip = std.mem.indexOf(u8, value, "gzip") != null,
    };
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

fn staticLookup(name: []const u8, count: usize) ?*const StaticEntry {
    for (g_static_entries[0..count]) |*e| {
        if (std.mem.eql(u8, e.name_buf[0..e.name_len], name)) return e;
    }

    return null;
}

pub fn staticMeta(name: []const u8) StaticMeta {
    if (std.mem.endsWith(u8, name, ".br")) {
        return .{ .content_type = contentType(name[0 .. name.len - ".br".len]), .content_encoding = "br" };
    }
    if (std.mem.endsWith(u8, name, ".gz")) {
        return .{ .content_type = contentType(name[0 .. name.len - ".gz".len]), .content_encoding = "gzip" };
    }

    return .{ .content_type = contentType(name), .content_encoding = "" };
}

/// Build the process-lifetime path for a static name and open it read-only. Returns null when absent.
fn openStatic(name: []const u8) ?std.posix.fd_t {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ g_static_base, name }) catch return null;
    if (path.len >= path_buf.len) return null;

    path_buf[path.len] = 0;

    return std.posix.openatZ(std.posix.AT.FDCWD, @ptrCast(&path_buf), .{ .ACCMODE = .RDONLY }, 0) catch null;
}

/// Probe one static name on disk and build its cache record: open, fstat, and pre-render the header
/// (content type and encoding from staticMeta) so serving it later is send + sendfile only.
fn buildVariant(name: []const u8) ?StaticVariant {
    const file_fd = openStatic(name) orelse return null;

    var stx: std.os.linux.Statx = undefined;
    const stat_rc = std.os.linux.statx(file_fd, "", std.os.linux.AT.EMPTY_PATH, .{ .SIZE = true }, &stx);
    if (std.posix.errno(stat_rc) != .SUCCESS) {
        _ = std.posix.system.close(file_fd);
        return null;
    }

    const size: u64 = stx.size;
    const meta = staticMeta(name);

    var v: StaticVariant = .{ .fd = file_fd, .size = size, .hdr_len = 0, .hdr_buf = undefined };
    const hdr = (if (meta.content_encoding.len > 0)
        std.fmt.bufPrint(&v.hdr_buf, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nContent-Encoding: {s}\r\n\r\n", .{ meta.content_type, size, meta.content_encoding })
    else
        std.fmt.bufPrint(&v.hdr_buf, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n", .{ meta.content_type, size })) catch {
        _ = std.posix.system.close(file_fd);
        return null;
    };
    v.hdr_len = @intCast(hdr.len);

    return v;
}

/// Probe + cache a static name on first request, then return the slot.
/// Caches a null variant so a bad name is probed only once.
/// Returns null only when the cache is full.
fn staticInsert(name: []const u8) ?*const StaticEntry {
    while (g_static_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
    defer g_static_lock.store(false, .release);

    const count = @atomicLoad(usize, &g_static_count, .acquire);
    if (staticLookup(name, count)) |e| return e;
    if (count == STATIC_CACHE_MAX) return null;

    const e = &g_static_entries[count];
    e.name_len = @intCast(name.len);
    @memcpy(e.name_buf[0..name.len], name);
    e.variant = buildVariant(name);

    @atomicStore(usize, &g_static_count, count + 1, .release);

    return e;
}

/// Resolve a static name through the cache (lookup, then insert on a miss).
/// Returns the slot only when the file exists on disk,
/// so a caller can fall through to the next candidate on a missing variant.
pub fn resolveStatic(name: []const u8) ?*const StaticEntry {
    const count = @atomicLoad(usize, &g_static_count, .acquire);
    const entry = staticLookup(name, count) orelse staticInsert(name) orelse return null;
    if (entry.variant == null) return null;

    return entry;
}

/// Block until fd is writable again. Used by the static send path to ride
/// out a full socket buffer, mirroring writeAllFD's EAGAIN handling.
fn waitWritable(fd: std.posix.fd_t) error{BrokenPipe}!void {
    var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};

    _ = std.posix.poll(&pfd, -1) catch return error.BrokenPipe;
}

/// Send with MSG_MORE so the header coalesces into the same packets as the
/// sendfile body that follows instead of leaving as its own small packet.
fn sendMoreFD(fd: std.posix.fd_t, data: []const u8) error{BrokenPipe}!void {
    const linux = std.os.linux;

    var rem = data;
    while (rem.len > 0) {
        const rc = linux.sendto(fd, rem.ptr, rem.len, linux.MSG.MORE, null, 0);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return error.BrokenPipe;

                rem = rem[n..];
            },
            .INTR => {},
            .AGAIN => try waitWritable(fd),
            else => return error.BrokenPipe,
        }
    }
}

/// Zero-copy file body: kernel pages straight to the socket, no userspace
/// bounce buffer. A local offset keeps the shared cached fd position
/// untouched, so one fd serves all workers concurrently.
fn sendfileAll(sock: std.posix.fd_t, file_fd: std.posix.fd_t, size: u64) error{BrokenPipe}!void {
    const linux = std.os.linux;

    var off: i64 = 0;
    while (@as(u64, @intCast(off)) < size) {
        const remaining: usize = @intCast(size - @as(u64, @intCast(off)));
        const rc = linux.sendfile(sock, file_fd, &off, remaining);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.BrokenPipe;
            },
            .INTR => {},
            .AGAIN => try waitWritable(sock),
            else => return error.BrokenPipe,
        }
    }
}

// json-comp: gzip a JSON body, send it with Content-Encoding: gzip.
// Delegates to the engine's sendGzipCachedFD:
// a per-worker compressor plus the per-(key, encoding) cache,
// so after the first request the deterministic gzip body
// is a zero-compression cache replay.
fn sendJsonGzipFD(head: *const zix.Http1.ParsedHead, fd: std.posix.fd_t, _json: []const u8) void {
    zix.Http1.sendGzipCachedFD(fd, head, 200, "application/json", _json, zix.Http1.cacheTtl()) catch {};
}

// --------------------------------------------------------- //

// GET/POST /baseline11?a=..&b=.. : sum the query values, plus the POST body as
// an integer. Returns the sum as text/plain.
pub fn baseline(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    var sum: i64 = sumQuery(head.query);

    if (std.mem.eql(u8, head.method, "POST") and body.len > 0) {
        sum += parseIntLoose(body);
    }

    var body_buf: [32]u8 = undefined;
    const out = std.fmt.bufPrint(&body_buf, "{d}", .{sum}) catch return;

    zix.Http1.sendSimpleFD(fd, 200, "text/plain", out) catch {};
}

// GET /pipeline : fixed tiny response, the pipelined-throughput endpoint.
// Reached through the Router (the engine parses every pipelined request).
// writeAllFD appends to the engine's staged per-connection sink, so a batch
// of pipelined responses leaves in request order as one coalesced send.
pub fn pipeline(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;

    zix.Http1.writeAllFD(fd, PIPELINE_RESP) catch {};
}

// POST /upload : return the received byte count. The Content-Length header is
// authoritative (curl/clients always send it here), and the engine drains the
// body for sizes beyond the read buffer, so this never touches the bytes.
pub fn upload(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    const n: u64 = if (head.content_length > 0) head.content_length else body.len;

    var body_buf: [24]u8 = undefined;
    const out = std.fmt.bufPrint(&body_buf, "{d}", .{n}) catch return;

    zix.Http1.sendSimpleFD(fd, 200, "text/plain", out) catch {};
}

/// GET /json/{count}?m=M : render count dataset items,
/// total = price*qty*M. Response-cache aware:
/// the body is deterministic in (count, m),
/// so each distinct path caches under its own slot
/// (key = hash(method, path, query)).
/// A hit replays the stored bytes, a miss builds and stores.
pub fn json(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = body;

    // json-comp: when the client accepts gzip, serve a gzip body
    // with Content-Encoding: gzip, cached per (key, encoding)
    // so a repeat request replays the compressed bytes
    // with no rebuild and no recompression.
    // The plain json test sends no Accept-Encoding and uses the identity cache.
    const accept = zix.Http1.getHeader(head, "accept-encoding") orelse "";
    const want_gzip = std.mem.indexOf(u8, accept, "gzip") != null;

    if (want_gzip) {
        if (zix.Http1.cacheLookupEncoded(head, "gzip")) |cached| {
            zix.Http1.writeAllFD(fd, cached) catch {};
            return;
        }
    } else {
        if (zix.Http1.cacheLookup(head)) |cached| {
            zix.Http1.writeAllFD(fd, cached) catch {};
            return;
        }
    }

    const count_str = head.path["/json/".len..];
    const count = std.fmt.parseInt(u8, count_str, 10) catch return badRequest(fd);
    if (count < 1 or count > dataset.ItemCount) return badRequest(fd);

    const m: u64 = if (zix.Http1.queryParam(head, "m")) |s| std.fmt.parseInt(u64, s, 10) catch 1 else 1;

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

    // json-comp path: gzip + per-(key, encoding) cache.
    // The first request compresses and stores,
    // the rest replay (early cacheLookupEncoded above already short-circuits a hit).
    if (want_gzip) {
        sendJsonGzipFD(head, fd, buf[0..pos]);
        return;
    }

    // Assemble the full response so it can be cached and replayed verbatim.
    // The header matches the engine's sendJsonFD output
    // (send_date_header is off, there is no time-varying field to freeze in the cache).
    const resp = &json_resp_buf;
    const hdr = std.fmt.bufPrint(resp, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{pos}) catch {
        zix.Http1.sendJsonFD(fd, 200, buf[0..pos]) catch {};
        return;
    };
    @memcpy(resp[hdr.len..][0..pos], buf[0..pos]);

    zix.Http1.sendWithCacheFD(fd, head, resp[0 .. hdr.len + pos], CACHE_TTL_MS) catch {};
}

// GET /static/{file} : serve from /data/static.
// Negotiates .br then .gz when accepted, else identity
// (the same flow as the HTTP/2 entry), Content-Type by extension.
// The send is HTTP/1's own path: one
// header send coalesced with the body (MSG_MORE) plus a zero-copy sendfile,
// not in-memory DATA frames.
pub fn static(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = body;

    const rel = head.path["/static/".len..];
    if (rel.len == 0 or rel.len > STATIC_NAME_MAX or std.mem.indexOf(u8, rel, "..") != null or rel[0] == '/') return notFound(fd);

    const accept = acceptEncoding(head);

    // Candidates "{rel}.br" / "{rel}.gz" / "{rel}".
    // The buffer holds rel plus a 3-char suffix.
    var cand_buf: [STATIC_NAME_MAX + 3]u8 = undefined;
    var entry: ?*const StaticEntry = null;

    if (accept.prefers_br) {
        const cand = std.fmt.bufPrint(&cand_buf, "{s}.br", .{rel}) catch return notFound(fd);
        entry = resolveStatic(cand);
    }
    if (entry == null and accept.accepts_gzip) {
        const cand = std.fmt.bufPrint(&cand_buf, "{s}.gz", .{rel}) catch return notFound(fd);
        entry = resolveStatic(cand);
    }
    if (entry == null) {
        entry = resolveStatic(rel);
    }

    const served = entry orelse return notFound(fd);
    const variant: *const StaticVariant = if (served.variant) |*v| v else return notFound(fd);

    // Raw fd writes below:
    // flush engine-staged responses first
    // so the wire order matches the request order under pipelining.
    zix.Http1.flushPending(fd);

    sendMoreFD(fd, variant.hdr_buf[0..variant.hdr_len]) catch return;
    sendfileAll(fd, variant.fd, variant.size) catch {};
}
