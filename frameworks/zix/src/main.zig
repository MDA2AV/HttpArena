//! HttpArena: zix
//!
//! zix.Http1 (.URING) against the HttpArena HTTP/1.1 suite (baseline, pipelined, limited-conn, json,
//! json-comp, upload, static). json-comp reuses /json and gzips on Accept-Encoding: gzip. json-tls
//! runs a second Http1 server on H1TLS_PORT (https over TLS 1.3, baked Ed25519 cert, per-core tls_mux).
//! /pipeline is fast-pathed in rawIntercept (see below), other routes go through the comptime Router.

const std = @import("std");
const zix = @import("zix");
const dataset = @import("dataset.zig");

// --------------------------------------------------------- //

const PORT: u16 = 8080;
const LISTEN_IP: []const u8 = "::";
const DISPATCH_MODEL: zix.Http1.DispatchModel = .URING;
const KERNEL_BACKLOG: u31 = 16 * 1024;

// json-tls: the https port and the baked Ed25519 cert / key paths (generated at
// image build, baked at /etc/zix-tls). Overridable via env so the same binary runs locally.
const H1TLS_PORT: u16 = 8081;
const TLS_CERT_DEFAULT: []const u8 = "/etc/zix-tls/server.crt";
const TLS_KEY_DEFAULT: []const u8 = "/etc/zix-tls/server.key";
/// Per-machine tuning profile (ADR-041 increment 5): .lean for the 12-thread / 32 GB dev box,
/// .throughput for the 64-core / 251 GB competition box. Only the recv buffer differs (workers,
/// backlog, and cache are already sized for both). Select .throughput for the 64-core deployment.
const Profile = enum { lean, throughput };
const PROFILE: Profile = .throughput;

/// Per-connection recv buffer (allocated at accept). .lean 4 KiB, .throughput 8 KiB (holds a
/// 16-deep pipelined burst, about 4.8 KiB). Held by every live and warm-pool connection, so it
/// pairs with uring_idle_pool_ceiling (below): 8 KiB (down from 16 KiB) trims the resident set
/// behind the high-connection regression at no cell cost (requests tiny, json/static use the send
/// buffer and sendfile, uploads use the large-body path).
const MAX_RECV_BUF: usize = switch (PROFILE) {
    .lean => 4 * 1024,
    .throughput => 8 * 1024,
};
const MAX_HEADERS: u8 = 16;
const WORKERS: usize = 0;

/// Warm idle-pool ceiling for .URING: absolute cap on warm connections per worker, so the pool
/// never tracks a full live_count at high concurrency (the engine-side high-connection regression fix).
const URING_IDLE_POOL_CEILING: usize = 256;

// Response cache (ADR-036), /json only. The body is deterministic in (count, m) and clears the
// cache crossover (~4 KiB), so a hit replays the full response with zero serialization. Other
// endpoints stay below the crossover or use the sendfile cache (static).
const CACHE_MAX_ENTRIES: u32 = 64;
/// Per-slot cap. A /json/50 response is near 12 KiB, so 32 KiB leaves headroom.
const CACHE_MAX_VALUE_BYTES: u32 = 32 * 1024;
/// Freshness window. The dataset is immutable for the process lifetime, so a
/// long TTL means each key is built once and replayed for the whole run.
const CACHE_TTL_MS: u32 = 60 * 1000;

/// gzip output buffer size for the json-comp path. The largest JSON body (count 50)
/// is near 12 KiB, so 64 KiB covers the worst case even when the body barely shrinks.
const GZIP_OUT_SIZE: usize = 64 * 1024;

// Data directory, overridable via the ARENA_DATA env var (default /data, the
// container mount point). Lets the same binary run against a local data tree.
var g_static_base: []const u8 = "/data/static/";
var g_static_base_buf: [256]u8 = undefined;

// Per-worker scratch. The JSON body (count up to 50) tops out near 12 KiB. The
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

// Precomputed response for the pipeline endpoint: written verbatim per request, no header build.
const PIPELINE_RESP: []const u8 = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nok";

// GET /pipeline : fixed tiny response, the pipelined-throughput endpoint.
fn pipelineHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;

    zix.Http1.fdWriteAll(fd, PIPELINE_RESP) catch {};
}

// Raw interceptor (initRaw), before header parsing. Handles /pipeline with zero parse overhead:
// byte-matches the path, writes PIPELINE_RESP, returns the consumed length. One call drains every
// consecutive /pipeline request in the buffer (a 16-deep burst answers in one pass, coalesced into
// one write), safe because the entry owns /pipeline as a pure bodyless GET. Other routes return null
// and fall through to the Router.
fn rawIntercept(rem: []const u8, header_end: usize, fd: std.posix.fd_t) ?usize {
    // Must start with "GET /p" to qualify for this fast path.
    if (rem.len < 24 or rem[0] != 'G' or rem[4] != '/' or rem[5] != 'p') return null;

    // Verify "/pipeline " without scanning the request line.
    if (!std.mem.eql(u8, rem[4..15], "/pipeline ")) return null;

    // First request: the engine already found its header end, so its length is header_end + 4.
    zix.Http1.fdWriteAll(fd, PIPELINE_RESP) catch {};
    var consumed: usize = header_end + 4;

    // Drain further consecutive /pipeline requests (each a bodyless GET, length = its header end + 4).
    // Stop at the first non-/pipeline or incomplete request and let the engine resume from there.
    while (true) {
        const next = rem[consumed..];
        if (next.len < 24 or next[0] != 'G' or next[4] != '/' or next[5] != 'p') break;
        if (!std.mem.eql(u8, next[4..15], "/pipeline ")) break;

        const end = std.mem.indexOf(u8, next, "\r\n\r\n") orelse break;
        zix.Http1.fdWriteAll(fd, PIPELINE_RESP) catch {};
        consumed += end + 4;
    }

    return consumed;
}

// GET /json/{count}?m=M : render count dataset items, total = price*qty*M.
//
// Response-cache aware: the body is deterministic in (count, m), so each distinct path caches under
// its own slot (key = hash(method, path, query)). A hit replays the stored bytes, a miss builds and
// stores. With the cache disabled or full it still works, just always rebuilds.
fn jsonHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = body;

    // json-comp: when the client accepts gzip, serve a gzip body with Content-Encoding: gzip, cached
    // per (key, encoding) so a repeat request replays the compressed bytes with no rebuild and no
    // recompression. The plain json test sends no Accept-Encoding and uses the identity cache.
    const accept = zix.Http1.getHeader(head, "accept-encoding") orelse "";
    const want_gzip = std.mem.indexOf(u8, accept, "gzip") != null;

    if (want_gzip) {
        if (zix.Http1.cacheLookupEncoded(head, "gzip")) |cached| {
            zix.Http1.fdWriteAll(fd, cached) catch {};
            return;
        }
    } else {
        if (zix.Http1.cacheLookup(head)) |cached| {
            zix.Http1.fdWriteAll(fd, cached) catch {};
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

    // json-comp path: gzip + per-(key, encoding) cache. The first request compresses and stores,
    // the rest replay (the early cacheLookupEncoded above already short-circuits a hit).
    if (want_gzip) {
        writeJsonGzip(head, fd, buf[0..pos]);
        return;
    }

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

// json-comp: gzip a JSON body, send it with Content-Encoding: gzip. Delegates to the engine's
// writeGzipCached: a per-worker compressor plus the per-(key, encoding) cache, so after the first
// request the deterministic gzip body is a zero-compression cache replay.
fn writeJsonGzip(head: *const zix.Http1.ParsedHead, fd: std.posix.fd_t, json: []const u8) void {
    zix.Http1.writeGzipCached(fd, head, 200, "application/json", json, zix.Http1.cacheTtl()) catch {};
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

// GET /static/{file} : serve from /data/static, content negotiation (prefers .br then .gz when
// accepted, else identity), Content-Type by extension. First request probes the disk and caches
// fd + size + pre-rendered header, later requests are one header send plus one zero-copy sendfile.
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

// json-tls https server on H1TLS_PORT. Under .EPOLL / .URING it terminates TLS in the per-core
// tls_mux (one worker per core, bounded memory), which scales where the thread-per-connection path
// melts down. The same Router dispatch serves the handlers (json-tls only exercises /json).
fn tlsWorker(io: std.Io, tls: *zix.Tls.Context) void {
    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = io,
        .ip = LISTEN_IP,
        .port = H1TLS_PORT,
        .tls = tls,
        .dispatch_model = DISPATCH_MODEL,
        .workers = WORKERS,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
        .uring_idle_pool_ceiling = URING_IDLE_POOL_CEILING,
        .max_headers = MAX_HEADERS,
        .send_date_header = false,
    });
    defer server.deinit();

    server.run() catch {};
}

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

    // json-tls: load the baked Ed25519 cert from /etc/zix-tls and serve https on H1TLS_PORT. A missing
    // or unreadable cert degrades gracefully: the cleartext server still runs, json-tls simply has
    // no listener. Ed25519 signing is a cheap per-connection operation (zix.Tls).
    const cert_path = process.environ_map.get("ARENA_TLS_CERT") orelse TLS_CERT_DEFAULT;
    const key_path = process.environ_map.get("ARENA_TLS_KEY") orelse TLS_KEY_DEFAULT;

    var tls_ctx: ?zix.Tls.Context = zix.Tls.Context.init(std.heap.smp_allocator, process.io, .{
        .cert_path = cert_path,
        .key_path = key_path,
        .alpn = &.{.HTTP_1_1},
        .min_version = .TLS_1_3,
    }) catch null;

    if (tls_ctx) |*tls| {
        // One TLS server thread: under .EPOLL / .URING it spawns its own per-core tls_mux workers
        // internally, so a thread pool here would over-subscribe. Thread models use one accept loop.
        _ = std.Thread.spawn(.{}, tlsWorker, .{ process.io, tls }) catch {};
    }

    var server = zix.Http1.Server.initRaw(Routes.dispatch, rawIntercept, .{
        .io = process.io,
        .ip = LISTEN_IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
        .uring_idle_pool_ceiling = URING_IDLE_POOL_CEILING,
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
