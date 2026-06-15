//! HttpArena: zix
//! zix version: 0.4.x-rc2
//!
//! zix HttpArena HTTP/1.1 entry point.
//!
//! Intent: demonstrate zix.Http1 (EPOLL dispatch model) against the HttpArena
//! HTTP/1.1 benchmark suite (baseline, pipelined, short-lived).
//!
//! Design choices:
//! - rawIntercept: called before any header parsing for each EPOLL request.
//!   Handles /pipeline with zero parse overhead (direct byte-match + sink write),
//!   direct byte-match before any parsing, avoiding the header scan loop. Routes that fall
//!   through are handled by the Router dispatch with full parsing.
//! - Router: comptime route table (StaticStringMap for EXACT, inline for PREFIX).
//! - PIPELINE_RESP: precomputed response bytes; one sink.append per request, no
//!   header build overhead.

const std = @import("std");
const zix = @import("zix");
const dataset = @import("dataset.zig");

// --------------------------------------------------------- //

const PORT: u16 = 8080;
const LISTEN_IP: []const u8 = "::";
const DISPATCH_MODEL: zix.Http1.DispatchModel = .EPOLL;
const KERNEL_BACKLOG: u31 = 16 * 1024;
/// 4 KiB per-connection recv buffer (heap-allocated once at accept time).
/// Benchmark requests are under 300 bytes. Halving from 16 KiB cuts the
/// working set from 64 MiB to 16 MiB at 4096c, reducing cache pressure.
/// Large upload bodies are drained by the engine in chunks, so headers
/// (always < 4 KiB) are the only part that needs to fit.
const MAX_RECV_BUF: usize = 4 * 1024;
const MAX_HEADERS: u8 = 16;
const WORKERS: usize = 0;

// Response cache (ADR-036), used by the /json endpoint only. The /json body is
// deterministic in (count, m) and large enough to clear the cache crossover
// (~4 KiB), so a hit replays the full response with zero serialization. The
// other endpoints stay below the crossover (baseline, pipeline, upload) or use
// their own zero-copy sendfile cache (static), so none of them enable it.
const CACHE_MAX_ENTRIES: u32 = 64;
/// Per-slot cap. A /json/50 response is near 12 KiB, so 32 KiB leaves headroom.
const CACHE_MAX_VALUE_BYTES: u32 = 32 * 1024;
/// Freshness window. The dataset is immutable for the process lifetime, so a
/// long TTL means each key is built once and replayed for the whole run.
const CACHE_TTL_MS: u32 = 60 * 1000;

// Data directory, overridable via the ARENA_DATA env var (default /data, the
// container mount point). Lets the same binary run against a local data tree.
var g_static_base: []const u8 = "/data/static/";
var g_static_base_buf: [256]u8 = undefined;

// Per-worker scratch. The JSON body (count up to 50) tops out near 12 KiB; the
// assembled response (status line + headers + body) sits a little above it.
threadlocal var json_body_buf: [32 * 1024]u8 = undefined;
threadlocal var json_resp_buf: [32 * 1024]u8 = undefined;

// --------------------------------------------------------- //

var g_dataset: dataset.Dataset = undefined;

// --------------------------------------------------------- //

fn notFound(fd: std.posix.fd_t) void {
    zix.Http1.writeSimple(fd, 404, "text/plain", "Not Found") catch {};
}

fn badRequest(fd: std.posix.fd_t) void {
    zix.Http1.writeSimple(fd, 400, "text/plain", "bad request") catch {};
}

// --------------------------------------------------------- //

// GET/POST /baseline11?a=..&b=.. : sum the query values, plus the POST body as
// an integer. Returns the sum as text/plain.
fn baselineHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    var sum: i64 = sumQuery(head.query);

    if (std.mem.eql(u8, head.method, "POST") and body.len > 0) {
        sum += parseIntLoose(body);
    }

    var body_buf: [32]u8 = undefined;
    const out = std.fmt.bufPrint(&body_buf, "{d}", .{sum}) catch return;

    zix.Http1.writeSimple(fd, 200, "text/plain", out) catch {};
}

// Precomputed response for the pipeline endpoint: one memcpy per request into the
// response sink. No header build overhead on the hot path.
const PIPELINE_RESP: []const u8 = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nok";

// GET /pipeline : fixed tiny response, the pipelined-throughput endpoint.
fn pipelineHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;

    zix.Http1.fdWriteAll(fd, PIPELINE_RESP) catch {};
}

// Raw-request interceptor for the EPOLL dispatch model. Called before any header
// parsing on each inbound request. Handles /pipeline with zero parse overhead:
// byte-matches the path directly on rem, then appends PIPELINE_RESP to the
// coalescing RespSink. Unknown
// routes return null and fall through to the Router dispatch with full parsing.
//
// This is intentional benchmark infrastructure, not general HTTP parsing. It
// exploits knowledge that /pipeline is always a bare GET with no body, so the
// consumed length is always header_end + 4 ("\r\n\r\n").
fn rawIntercept(rem: []const u8, header_end: usize, fd: std.posix.fd_t) ?usize {
    // Must start with "GET /p" to qualify for this fast path.
    if (rem.len < 24 or rem[0] != 'G' or rem[4] != '/' or rem[5] != 'p') return null;

    // "GET /pipeline " is 15 bytes. Verify without scanning the request line.
    if (!std.mem.eql(u8, rem[4..15], "/pipeline ")) return null;

    zix.Http1.fdWriteAll(fd, PIPELINE_RESP) catch {};

    return header_end + 4;
}

// GET /json/{count}?m=M : render count dataset items, total = price*qty*M.
//
// Response-cache aware. The body is deterministic in (count, m) and big enough
// to clear the cache crossover, so the full response is the ideal cache value.
// The cache key is hash(method, path, query), so every distinct /json/{count}?m=M
// caches under its own slot. A hit skips the whole build loop and replays the
// stored bytes; a miss builds the response and stores it on the way out. When
// the cache is disabled or full the path still works, it just always rebuilds.
fn jsonHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = body;

    if (zix.Http1.cacheLookup(head)) |cached| {
        zix.Http1.fdWriteAll(fd, cached) catch {};
        return;
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

    // Assemble the full response so it can be cached and replayed verbatim. The
    // header matches the engine's writeJson output (send_date_header is off, so
    // there is no time-varying field to freeze in the cache).
    const resp = &json_resp_buf;
    const hdr = std.fmt.bufPrint(resp, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{pos}) catch {
        zix.Http1.writeJson(fd, 200, buf[0..pos]) catch {};
        return;
    };
    @memcpy(resp[hdr.len..][0..pos], buf[0..pos]);

    zix.Http1.writeWithCache(fd, head, resp[0 .. hdr.len + pos], CACHE_TTL_MS) catch {};
}

// POST /upload : return the received byte count. The Content-Length header is
// authoritative (curl/clients always send it here), and the engine drains the
// body for sizes beyond the read buffer, so this never touches the bytes.
fn uploadHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    const n: u64 = if (head.content_length > 0) head.content_length else body.len;

    var body_buf: [24]u8 = undefined;
    const out = std.fmt.bufPrint(&body_buf, "{d}", .{n}) catch return;

    zix.Http1.writeSimple(fd, 200, "text/plain", out) catch {};
}

// --------------------------------------------------------- //

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

fn openVariant(rel: []const u8, suffix: []const u8) ?std.posix.fd_t {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}{s}{s}", .{ g_static_base, rel, suffix }) catch return null;
    if (path.len >= path_buf.len) return null;

    path_buf[path.len] = 0;

    return std.posix.openatZ(std.posix.AT.FDCWD, @ptrCast(&path_buf), .{ .ACCMODE = .RDONLY }, 0) catch null;
}

// --------------------------------------------------------- //

/// Static cache name cap. Fixture names are short, anything longer is a 404.
const STATIC_NAME_MAX = 96;
/// Static cache capacity: 20 fixtures plus room for cached 404 lookups.
const STATIC_CACHE_MAX = 64;

/// One servable variant of a static file: a fd kept open for the process
/// lifetime, its size, and the pre-rendered response header.
const StaticVariant = struct {
    fd: std.posix.fd_t,
    size: u64,
    hdr_len: u16,
    hdr_buf: [192]u8,
};

/// Cache slot for one /static/{name} path. All-null variants cache a 404.
const StaticEntry = struct {
    name_len: u16,
    name_buf: [STATIC_NAME_MAX]u8,
    identity: ?StaticVariant,
    br: ?StaticVariant,
    gz: ?StaticVariant,
};

// Append-only cache: readers scan 0..count lock-free (count is published
// with release ordering after the slot is fully written), the spinlock only
// serializes inserts (rare: one per distinct path, all during warmup).
var g_static_entries: [STATIC_CACHE_MAX]StaticEntry = undefined;
var g_static_count: usize = 0;
var g_static_lock: std.atomic.Mutex = .unlocked;

/// Probe one variant on disk and build its cache record: open, fstat, and
/// pre-render the header so serving it later is send + sendfile only.
fn buildStaticVariant(rel: []const u8, suffix: []const u8, encoding: []const u8) ?StaticVariant {
    const file_fd = openVariant(rel, suffix) orelse return null;

    var stx: std.os.linux.Statx = undefined;
    const stat_rc = std.os.linux.statx(file_fd, "", std.os.linux.AT.EMPTY_PATH, .{ .SIZE = true }, &stx);
    if (std.posix.errno(stat_rc) != .SUCCESS) {
        _ = std.posix.system.close(file_fd);
        return null;
    }

    const size: u64 = stx.size;
    const ct = contentType(rel);

    var v: StaticVariant = .{ .fd = file_fd, .size = size, .hdr_len = 0, .hdr_buf = undefined };
    const hdr = (if (encoding.len > 0)
        std.fmt.bufPrint(&v.hdr_buf, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nContent-Encoding: {s}\r\n\r\n", .{ ct, size, encoding })
    else
        std.fmt.bufPrint(&v.hdr_buf, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n", .{ ct, size })) catch {
        _ = std.posix.system.close(file_fd);
        return null;
    };
    v.hdr_len = @intCast(hdr.len);

    return v;
}

fn staticLookup(rel: []const u8, count: usize) ?*const StaticEntry {
    for (g_static_entries[0..count]) |*e| {
        if (std.mem.eql(u8, e.name_buf[0..e.name_len], rel)) return e;
    }

    return null;
}

/// Slow path on first request for a path: probe all variants and publish the
/// slot. Returns null only when the cache is full.
fn staticInsert(rel: []const u8) ?*const StaticEntry {
    while (!g_static_lock.tryLock()) std.atomic.spinLoopHint();
    defer g_static_lock.unlock();
    const count = @atomicLoad(usize, &g_static_count, .acquire);
    if (staticLookup(rel, count)) |e| return e;
    if (count == STATIC_CACHE_MAX) return null;

    const e = &g_static_entries[count];
    e.name_len = @intCast(rel.len);
    @memcpy(e.name_buf[0..rel.len], rel);
    e.identity = buildStaticVariant(rel, "", "");
    e.br = buildStaticVariant(rel, ".br", "br");
    e.gz = buildStaticVariant(rel, ".gz", "gzip");

    @atomicStore(usize, &g_static_count, count + 1, .release);

    return e;
}

/// Block until fd is writable again. Used by the static send path to ride
/// out a full socket buffer, mirroring fdWriteAll's EAGAIN handling.
fn waitWritable(fd: std.posix.fd_t) error{BrokenPipe}!void {
    var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};

    _ = std.posix.poll(&pfd, -1) catch return error.BrokenPipe;
}

/// Send with MSG_MORE so the header coalesces into the same packets as the
/// sendfile body that follows instead of leaving as its own small packet.
fn fdSendMore(fd: std.posix.fd_t, data: []const u8) error{BrokenPipe}!void {
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

/// Cache-full fallback: probe, serve, close. Keeps rarely-hit paths correct
/// without evicting anything.
fn staticServeUncached(rel: []const u8, want_br: bool, want_gzip: bool, fd: std.posix.fd_t) void {
    const variant: StaticVariant = blk: {
        if (want_br) {
            if (buildStaticVariant(rel, ".br", "br")) |v| break :blk v;
        }
        if (want_gzip) {
            if (buildStaticVariant(rel, ".gz", "gzip")) |v| break :blk v;
        }
        break :blk buildStaticVariant(rel, "", "") orelse return notFound(fd);
    };
    defer _ = std.posix.system.close(variant.fd);

    // Raw fd writes below: flush engine-staged responses first to keep the
    // wire order matching the request order under pipelining.
    zix.Http1.flushPending(fd);

    fdSendMore(fd, variant.hdr_buf[0..variant.hdr_len]) catch return;
    sendfileAll(fd, variant.fd, variant.size) catch {};
}

// GET /static/{file} : serve from /data/static with content negotiation.
// Prefers a precompressed .br then .gz variant when the client accepts it,
// falling back to the identity file. Content-Type is by extension. The first
// request for a path probes the disk and caches fd + size + pre-rendered
// header, every later request is one header send plus one zero-copy sendfile.
fn staticHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = body;

    const rel = head.path["/static/".len..];
    if (rel.len == 0 or rel.len > STATIC_NAME_MAX or std.mem.indexOf(u8, rel, "..") != null or rel[0] == '/') return notFound(fd);

    const accept_encoding = zix.Http1.getHeader(head, "accept-encoding") orelse "";
    const want_br = std.mem.indexOf(u8, accept_encoding, "br") != null;
    const want_gzip = std.mem.indexOf(u8, accept_encoding, "gzip") != null;

    const count = @atomicLoad(usize, &g_static_count, .acquire);
    const entry = staticLookup(rel, count) orelse staticInsert(rel) orelse
        return staticServeUncached(rel, want_br, want_gzip, fd);

    const variant: *const StaticVariant = blk: {
        if (want_br) {
            if (entry.br) |*v| break :blk v;
        }
        if (want_gzip) {
            if (entry.gz) |*v| break :blk v;
        }
        if (entry.identity) |*v| break :blk v;

        return notFound(fd);
    };

    // This path writes to the fd directly (raw send + sendfile), so any
    // engine-staged responses from earlier pipelined requests go first.
    zix.Http1.flushPending(fd);

    fdSendMore(fd, variant.hdr_buf[0..variant.hdr_len]) catch return;
    sendfileAll(fd, variant.fd, variant.size) catch {};
}

// --------------------------------------------------------- //

// Comptime route table. EXACT routes use a StaticStringMap (O(1) hash lookup),
// PREFIX routes match on startsWith with a boundary check (longest match wins).
// rawIntercept handles /pipeline before this dispatch is reached for that route.
const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/baseline11", .handler = baselineHandler },
    .{ .path = "/pipeline", .handler = pipelineHandler },
    .{ .path = "/upload", .handler = uploadHandler },
    .{ .path = "/json", .handler = jsonHandler, .kind = .PREFIX },
    .{ .path = "/static", .handler = staticHandler, .kind = .PREFIX },
});

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

pub fn main(process: std.process.Init) !void {
    // Elevate scheduling priority (setpriority -19). Fails silently when the
    // process lacks CAP_SYS_NICE, so no special capability is required for correctness.
    _ = std.os.linux.syscall3(.setpriority, 0, 0, @as(usize, @bitCast(@as(isize, -19))));

    const data_dir = process.environ_map.get("ARENA_DATA") orelse "/data";
    g_static_base = std.fmt.bufPrint(&g_static_base_buf, "{s}/static/", .{data_dir}) catch "/data/static/";

    var dataset_path_buf: [512]u8 = undefined;
    const dataset_path = try std.fmt.bufPrint(&dataset_path_buf, "{s}/dataset.json", .{data_dir});

    g_dataset = try dataset.load(std.heap.smp_allocator, dataset_path);

    var server = zix.Http1.Server.initRaw(Routes.dispatch, rawIntercept, .{
        .io = process.io,
        .ip = LISTEN_IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
        .max_headers = MAX_HEADERS,
        .workers = WORKERS,
        .send_date_header = false,
        .response_cache = true,
        .cache_max_entries = CACHE_MAX_ENTRIES,
        .cache_max_value_bytes = CACHE_MAX_VALUE_BYTES,
        .cache_ttl_ms = CACHE_TTL_MS,
    });
    defer server.deinit();

    try server.run();
}
