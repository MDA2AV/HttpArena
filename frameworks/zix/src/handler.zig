//! HttpArena: zix
//!
//! Route handlers: zero-copy static serving, br/gzip negotiation, cached
//! JSON. DB endpoints queue a job on the postgrez.Executor (owned by
//! dbpg.zig), which batches and pipelines the round trips off the engine
//! workers, run_batch below renders each result and writes the response raw
//! to the fd. Single-item crud reads serve from the in-process cache
//! (crudcache.zig), rediz mirrors fills and invalidations write-behind.

const std = @import("std");
const zix = @import("zix");

const postgrez = zix.Driver.postgrez;
const dataset = @import("dataset.zig");
const crudcache = @import("crudcache.zig");
const dbpg = @import("dbpg.zig");
const dbrd = @import("dbrd.zig");

// --------------------------------------------------------- //

// Precomputed response for the pipeline endpoint.
const PIPELINE_RESP: []const u8 = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nok";

/// Static cache name cap. Fixture names are short, anything longer is a 404.
pub const STATIC_NAME_MAX: usize = 96;
/// 20 fixtures times their (.br, .gz, identity) candidates plus headroom.
pub const STATIC_CACHE_MAX: usize = 128;

/// Long TTL: the dataset is immutable, each key is built once per run.
pub const CACHE_TTL_MS: u32 = 60 * 1000;

/// Accept-Encoding tokens the client advertised (substring scan, the bench
/// header needs no q-value parsing).
const AcceptEncoding = struct {
    prefers_br: bool,
    accepts_gzip: bool,
};

/// One servable static variant: a process-lifetime fd, its size, and the
/// pre-rendered response header.
const StaticVariant = struct {
    fd: std.posix.fd_t,
    size: u64,
    hdr_len: u16,
    hdr_buf: [192]u8,
};

/// Cache slot for one resolved static name. A null variant caches a miss
/// so a bad name is probed only once.
const StaticEntry = struct {
    name_len: u16,
    // rel plus a 3-char precompressed suffix (".br" or ".gz")
    name_buf: [STATIC_NAME_MAX + 3]u8,
    variant: ?StaticVariant,
};

/// Content type plus content encoding for a cached static name.
const StaticMeta = struct {
    content_type: []const u8,
    content_encoding: []const u8,
};

// --------------------------------------------------------- //

// Per-worker scratch, the JSON body (count up to 50) tops out near 12 KiB.
threadlocal var json_body_buf: [32 * 1024]u8 = undefined;
threadlocal var json_resp_buf: [32 * 1024]u8 = undefined;

// Append-only cache: readers scan 0..count lock-free, the spinlock only
// serializes inserts.
var g_static_entries: [STATIC_CACHE_MAX]StaticEntry = undefined;
var g_static_count: usize = 0;
var g_static_lock: std.atomic.Value(bool) = .init(false);

// Data directory (default /data, the container mount point).
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

// json-comp: gzip a JSON body through the engine's per-(key, encoding)
// cache, a repeat request replays the compressed bytes.
fn sendJsonGzipFD(head: *const zix.Http1.ParsedHead, fd: std.posix.fd_t, json: []const u8) void {
    zix.Http1.sendGzipCachedFD(fd, head, 200, "application/json", json, zix.Http1.cacheTtl()) catch {};
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

// GET /pipeline : fixed tiny response. writeAllFD appends to the engine's
// staged sink, a pipelined batch leaves in request order as one send.
pub fn pipeline(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;

    zix.Http1.writeAllFD(fd, PIPELINE_RESP) catch {};
}

// POST /upload : return the received byte count. Content-Length is
// authoritative, the engine drains oversized bodies.
pub fn upload(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    const n: u64 = if (head.content_length > 0) head.content_length else body.len;

    var body_buf: [24]u8 = undefined;
    const out = std.fmt.bufPrint(&body_buf, "{d}", .{n}) catch return;

    zix.Http1.sendSimpleFD(fd, 200, "text/plain", out) catch {};
}

/// GET /json/{count}?m=M : render count dataset items, total = price*qty*M.
/// The body is deterministic in (count, m), so each distinct path caches
/// under its own slot: a hit replays, a miss builds and stores.
pub fn jsonResp(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = body;

    // json-comp: a gzip-accepting client gets the per-(key, encoding)
    // cache, the plain json test uses the identity cache.
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

    // The PREFIX route also matches a bare /json (no trailing slash), which
    // would slice out of bounds below.
    if (head.path.len < "/json/".len) return badRequest(fd);

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

    if (want_gzip) {
        sendJsonGzipFD(head, fd, buf[0..pos]);
        return;
    }

    // Assemble the full response so it caches and replays verbatim (the
    // header matches the engine's sendJsonFD output).
    const resp = &json_resp_buf;
    const hdr = std.fmt.bufPrint(resp, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{pos}) catch {
        zix.Http1.sendJsonFD(fd, 200, buf[0..pos]) catch {};
        return;
    };
    @memcpy(resp[hdr.len..][0..pos], buf[0..pos]);

    zix.Http1.sendWithCacheFD(fd, head, resp[0 .. hdr.len + pos], CACHE_TTL_MS) catch {};
}

// GET /static/{file} : serve from /data/static. Negotiates .br then .gz
// when accepted, else identity. One header send coalesced with a zero-copy
// sendfile body.
pub fn static(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = body;

    // The PREFIX route also matches a bare /static (no trailing slash), which
    // would slice out of bounds below.
    if (head.path.len < "/static/".len) return notFound(fd);

    const rel = head.path["/static/".len..];
    if (rel.len == 0 or rel.len > STATIC_NAME_MAX or std.mem.indexOf(u8, rel, "..") != null or rel[0] == '/') return notFound(fd);

    const accept = acceptEncoding(head);

    // Candidates "{rel}.br" / "{rel}.gz" / "{rel}".
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

    // Raw fd writes below: flush engine-staged responses first so the wire
    // order matches the request order under pipelining.
    zix.Http1.flushPending(fd);

    sendMoreFD(fd, variant.hdr_buf[0..variant.hdr_len]) catch return;
    sendfileAll(fd, variant.fd, variant.size) catch {};
}

// --------------------------------------------------------- //

// DB endpoints. Column order is fixed by the SQL constants, the renderers
// decode cells by position with rawDecode.
const SQL_ASYNC_DB = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3";
const SQL_CRUD_LIST = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count, count(*) OVER() AS total FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3";
const SQL_CRUD_GET = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE id = $1";
const SQL_CRUD_UPSERT = "INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) VALUES ($1, $2, $3, $4, $5, true, '[]', 0, 0) ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, price = EXCLUDED.price, quantity = EXCLUDED.quantity";
const SQL_CRUD_UPDATE = "UPDATE items SET name = $2, category = $3, price = $4, quantity = $5 WHERE id = $1";

const CRUD_KEY_PREFIX = "crud:item:";
/// Mirror TTL, the write path additionally deletes the key.
const CRUD_CACHE_TTL_S: u64 = 1;

const ASYNC_DB_LIMIT_MAX: i64 = 50;
const CRUD_LIST_LIMIT_DEFAULT: i64 = 10;
const CRUD_LIST_LIMIT_MAX: i64 = 100;

// Per-executor scratch for the rendered DB bodies, the renderDbRow budget
// guard rejects an overflow with 503.
threadlocal var db_body_buf: [32 * 1024]u8 = undefined;

// Per-engine-worker arena for the crud POST/PUT JSON body parse.
threadlocal var tl_crud_arena: ?std.heap.ArenaAllocator = null;

/// Fields of a crud create/update body. PUT bodies carry no id (the id is
/// in the path), so every field defaults.
const CrudBody = struct {
    id: i64 = 0,
    name: []const u8 = "",
    category: []const u8 = "",
    price: i64 = 0,
    quantity: i64 = 0,
};

// --------------------------------------------------------- //

fn serviceUnavailable(fd: std.posix.fd_t) void {
    zix.Http1.sendSimpleFD(fd, 503, "text/plain", "Service Unavailable") catch {};
}

/// 503 the request after a PostgreSQL failure. A server-reported error
/// keeps the connection, anything else marks the batch broken for discard.
fn failDb(batch: *dbpg.DbExecutor.Batch, fd: std.posix.fd_t, err: anyerror) void {
    if (err != error.ServerError) batch.markBroken();

    serviceUnavailable(fd);
}

/// Drop the redis connection on a transport-shaped failure, keep it on a
/// server-reported error.
fn failCache(err: anyerror) void {
    if (err != error.ServerError) dbrd.drop();
}

fn cellInt(columns: []const postgrez.row.ColumnInfo, cells: []const ?[]const u8, index: usize) !i64 {
    const bytes = cells[index] orelse return error.BadCell;
    const column = columns[index];

    return postgrez.row.rawDecode(i64, @enumFromInt(column.type_oid), column.format, bytes);
}

fn cellBool(columns: []const postgrez.row.ColumnInfo, cells: []const ?[]const u8, index: usize) !bool {
    const bytes = cells[index] orelse return error.BadCell;
    const column = columns[index];

    return postgrez.row.rawDecode(bool, @enumFromInt(column.type_oid), column.format, bytes);
}

/// Raw cell bytes (text and jsonb columns). The slice points into the
/// receive buffer, valid until the next result.next().
fn cellStr(columns: []const postgrez.row.ColumnInfo, cells: []const ?[]const u8, index: usize) ![]const u8 {
    const bytes = cells[index] orelse return error.BadCell;
    const column = columns[index];

    return postgrez.row.rawDecode([]const u8, @enumFromInt(column.type_oid), column.format, bytes);
}

fn appendI64(out: []u8, pos: usize, value: i64) usize {
    var tmp: [24]u8 = undefined;
    const rendered = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch unreachable;
    @memcpy(out[pos..][0..rendered.len], rendered);

    return pos + rendered.len;
}

/// Append a JSON string body (quotes are the caller's), escaped. Worst
/// case is 6x the input, the renderDbRow budget accounts for it.
fn appendJsonStr(out: []u8, start: usize, value: []const u8) usize {
    const HEX = "0123456789abcdef";

    var pos = start;
    for (value) |ch| {
        switch (ch) {
            '"', '\\' => {
                out[pos] = '\\';
                out[pos + 1] = ch;
                pos += 2;
            },
            0x00...0x1f => {
                out[pos..][0..4].* = "\\u00".*;
                out[pos + 4] = HEX[ch >> 4];
                out[pos + 5] = HEX[ch & 0xf];
                pos += 6;
            },
            else => {
                out[pos] = ch;
                pos += 1;
            },
        }
    }

    return pos;
}

/// Render one items row as a JSON object, cells by SQL column order. tags
/// is jsonb text, emitted raw.
fn renderDbRow(out: []u8, start: usize, columns: []const postgrez.row.ColumnInfo, cells: []const ?[]const u8) !usize {
    const name = try cellStr(columns, cells, 1);
    const category = try cellStr(columns, cells, 2);
    const tags = try cellStr(columns, cells, 6);
    if (start + name.len * 6 + category.len * 6 + tags.len + 192 > out.len) return error.NoSpaceLeft;

    var pos = start;
    pos = appendStr(out, pos, "{\"id\":");
    pos = appendI64(out, pos, try cellInt(columns, cells, 0));
    pos = appendStr(out, pos, ",\"name\":\"");
    pos = appendJsonStr(out, pos, name);
    pos = appendStr(out, pos, "\",\"category\":\"");
    pos = appendJsonStr(out, pos, category);
    pos = appendStr(out, pos, "\",\"price\":");
    pos = appendI64(out, pos, try cellInt(columns, cells, 3));
    pos = appendStr(out, pos, ",\"quantity\":");
    pos = appendI64(out, pos, try cellInt(columns, cells, 4));
    pos = appendStr(out, pos, ",\"active\":");
    pos = appendStr(out, pos, if (try cellBool(columns, cells, 5)) "true" else "false");
    pos = appendStr(out, pos, ",\"tags\":");
    pos = appendStr(out, pos, tags);
    pos = appendStr(out, pos, ",\"rating\":{\"score\":");
    pos = appendI64(out, pos, try cellInt(columns, cells, 7));
    pos = appendStr(out, pos, ",\"count\":");
    pos = appendI64(out, pos, try cellInt(columns, cells, 8));
    pos = appendStr(out, pos, "}}");

    return pos;
}

/// Parse a crud create/update JSON body into CrudBody. Returned slices live
/// in the per-worker arena, valid until the next parse on this worker.
fn parseCrudBody(body: []const u8) ?CrudBody {
    if (tl_crud_arena == null) tl_crud_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);

    const arena = &tl_crud_arena.?;
    _ = arena.reset(.retain_capacity);

    return std.json.parseFromSliceLeaky(CrudBody, arena.allocator(), body, .{
        .ignore_unknown_fields = true,
    }) catch null;
}

// --------------------------------------------------------- //

/// Streamed render of the async-db result, rows go straight into out.
fn renderAsyncDb(result: *postgrez.Result, out: []u8) !usize {
    var pos: usize = 0;
    pos = appendStr(out, pos, "{\"items\":[");

    var count: usize = 0;
    while (try result.next()) |row_view| {
        if (count > 0) {
            out[pos] = ',';
            pos += 1;
        }
        pos = try renderDbRow(out, pos, result.columns, row_view.cells);
        count += 1;
    }

    pos = appendStr(out, pos, "],\"count\":");
    pos = appendInt(out, pos, count);
    out[pos] = '}';
    pos += 1;

    return pos;
}

/// Streamed render of the crud list page. total rides every row as a
/// count(*) OVER() column, one pass yields items and total.
fn renderCrudList(result: *postgrez.Result, page: i64, out: []u8) !usize {
    var pos: usize = 0;
    pos = appendStr(out, pos, "{\"items\":[");

    var total: i64 = 0;
    var count: usize = 0;
    while (try result.next()) |row_view| {
        if (count > 0) {
            out[pos] = ',';
            pos += 1;
        }
        pos = try renderDbRow(out, pos, result.columns, row_view.cells);
        total = try cellInt(result.columns, row_view.cells, 9);
        count += 1;
    }

    pos = appendStr(out, pos, "],\"total\":");
    pos = appendI64(out, pos, total);
    pos = appendStr(out, pos, ",\"page\":");
    pos = appendI64(out, pos, page);
    out[pos] = '}';
    pos += 1;

    return pos;
}

/// Render one crud item, null when the row does not exist.
fn renderCrudItem(result: *postgrez.Result, out: []u8) !?usize {
    const row_view = (try result.next()) orelse return null;

    return try renderDbRow(out, 0, result.columns, row_view.cells);
}

/// 200 JSON response with the X-Cache header the crud cache check reads.
fn sendCrudBody(fd: std.posix.fd_t, body: []const u8, cache_state: []const u8) void {
    var hdr_buf: [128]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Cache: {s}\r\nContent-Length: {d}\r\n\r\n", .{ cache_state, body.len }) catch return;

    zix.Http1.writeAllFD(fd, hdr) catch return;
    zix.Http1.writeAllFD(fd, body) catch {};
}

/// Drop the cached crud body on every write: the in-process slot first
/// (the read path), the Redis mirror write-behind.
fn invalidateCrud(id: i64) void {
    crudcache.remove(id);

    const cache = dbrd.conn() orelse return;

    var key_buf: [40]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, CRUD_KEY_PREFIX ++ "{d}", .{id}) catch return;

    cache.delDeferred(&.{key}) catch |err| failCache(err);
}

// --------------------------------------------------------- //

// Route handlers below run on the engine worker: parse, queue the job on
// the executor fleet, return without a response. A full queue sheds 503.

/// GET /async-db?min=A&max=B&limit=N : items with price BETWEEN A AND B,
/// LIMIT N clamped to 1..50.
pub fn asyncDb(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = body;

    const min: i64 = if (zix.Http1.queryParam(head, "min")) |raw| std.fmt.parseInt(i64, raw, 10) catch 0 else 0;
    const max: i64 = if (zix.Http1.queryParam(head, "max")) |raw| std.fmt.parseInt(i64, raw, 10) catch 0 else 0;
    var limit: i64 = if (zix.Http1.queryParam(head, "limit")) |raw| std.fmt.parseInt(i64, raw, 10) catch 10 else 10;
    if (limit < 1) limit = 1;
    if (limit > ASYNC_DB_LIMIT_MAX) limit = ASYNC_DB_LIMIT_MAX;

    const queued = submitJob(head, .{ .ASYNC_DB = .{
        .fd = fd,
        .min = min,
        .max = max,
        .limit = limit,
    } });
    if (!queued) serviceUnavailable(fd);
}

/// Queue a job on the fleet, or run it inline for a close-marked request:
/// the engine closes the fd right after the handler returns, so a deferred
/// executor write would race the close and drop the response.
fn submitJob(head: *const zix.Http1.ParsedHead, job: dbpg.Job) bool {
    if (head.keep_alive) return dbpg.submit(job);

    return dbpg.runInline(job);
}

fn crudList(head: *const zix.Http1.ParsedHead, fd: std.posix.fd_t) void {
    const category = zix.Http1.queryParam(head, "category") orelse "";
    var page: i64 = if (zix.Http1.queryParam(head, "page")) |raw| std.fmt.parseInt(i64, raw, 10) catch 1 else 1;
    var limit: i64 = if (zix.Http1.queryParam(head, "limit")) |raw| std.fmt.parseInt(i64, raw, 10) catch CRUD_LIST_LIMIT_DEFAULT else CRUD_LIST_LIMIT_DEFAULT;
    if (page < 1) page = 1;
    if (limit < 1) limit = CRUD_LIST_LIMIT_DEFAULT;
    if (limit > CRUD_LIST_LIMIT_MAX) limit = CRUD_LIST_LIMIT_MAX;
    if (category.len > dbpg.CATEGORY_MAX) return badRequest(fd);

    // list-page cache first: a hit answers on the engine worker
    const list_key = crudcache.listKey(category, page, limit);
    if (crudcache.listGet(list_key, &db_body_buf)) |len| {
        zix.Http1.sendJsonFD(fd, 200, db_body_buf[0..len]) catch {};

        return;
    }

    var job: dbpg.Job = .{ .CRUD_LIST = .{
        .fd = fd,
        .page = page,
        .limit = limit,
        .category_len = @intCast(category.len),
        .category_buf = undefined,
    } };
    @memcpy(job.CRUD_LIST.category_buf[0..category.len], category);

    if (!submitJob(head, job)) serviceUnavailable(fd);
}

fn crudCreate(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    const item = parseCrudBody(body) orelse return badRequest(fd);
    if (item.id < 1 or item.name.len == 0) return badRequest(fd);
    if (item.name.len > dbpg.NAME_MAX or item.category.len > dbpg.CATEGORY_MAX) return badRequest(fd);

    var job: dbpg.Job = .{ .CRUD_CREATE = .{
        .fd = fd,
        .id = item.id,
        .price = item.price,
        .quantity = item.quantity,
        .name_len = @intCast(item.name.len),
        .category_len = @intCast(item.category.len),
        .name_buf = undefined,
        .category_buf = undefined,
    } };
    @memcpy(job.CRUD_CREATE.name_buf[0..item.name.len], item.name);
    @memcpy(job.CRUD_CREATE.category_buf[0..item.category.len], item.category);

    if (!submitJob(head, job)) serviceUnavailable(fd);
}

fn crudUpdate(head: *const zix.Http1.ParsedHead, id: i64, body: []const u8, fd: std.posix.fd_t) void {
    const item = parseCrudBody(body) orelse return badRequest(fd);
    if (item.name.len > dbpg.NAME_MAX or item.category.len > dbpg.CATEGORY_MAX) return badRequest(fd);

    var job: dbpg.Job = .{ .CRUD_UPDATE = .{
        .fd = fd,
        .id = id,
        .price = item.price,
        .quantity = item.quantity,
        .name_len = @intCast(item.name.len),
        .category_len = @intCast(item.category.len),
        .name_buf = undefined,
        .category_buf = undefined,
    } };
    @memcpy(job.CRUD_UPDATE.name_buf[0..item.name.len], item.name);
    @memcpy(job.CRUD_UPDATE.category_buf[0..item.category.len], item.category);

    if (!submitJob(head, job)) serviceUnavailable(fd);
}

/// /crud/items dispatcher: list and create on the collection, read and
/// update on /crud/items/{id}.
pub fn crudItems(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    const sub = head.path["/crud/items".len..];

    if (sub.len == 0) {
        if (std.mem.eql(u8, head.method, "GET")) return crudList(head, fd);
        if (std.mem.eql(u8, head.method, "POST")) return crudCreate(head, body, fd);

        return notFound(fd);
    }

    if (sub[0] != '/' or sub.len == 1) return notFound(fd);
    const id = std.fmt.parseInt(i64, sub[1..], 10) catch return badRequest(fd);

    if (std.mem.eql(u8, head.method, "GET")) {
        // in-process cache first: a HIT answers on the engine worker and
        // never becomes a job
        if (crudcache.get(id, &db_body_buf)) |len| {
            sendCrudBody(fd, db_body_buf[0..len], "HIT");

            return;
        }

        if (!submitJob(head, .{ .CRUD_GET = .{ .fd = fd, .id = id } })) serviceUnavailable(fd);

        return;
    }
    if (std.mem.eql(u8, head.method, "PUT")) return crudUpdate(head, id, body, fd);

    return notFound(fd);
}

// --------------------------------------------------------- //

// Batch execution below runs on an executor thread, never on an engine
// worker. One batch pipelines every job on the held connection: statements
// resolve first (a prepare must precede any queued execution), then every
// execution queues (sendRows), then results render in order (awaitRows).

fn jobFd(job: dbpg.Job) std.posix.fd_t {
    return switch (job) {
        .ASYNC_DB => |request| request.fd,
        .CRUD_LIST => |request| request.fd,
        .CRUD_GET => |request| request.fd,
        .CRUD_CREATE => |request| request.fd,
        .CRUD_UPDATE => |request| request.fd,
    };
}

/// Execute one drained batch and write every response. Registered with the
/// postgrez.Executor as its run function: batch hands out prepared statements
/// on the held connection, this pipelines and renders them.
pub fn runBatch(batch: *dbpg.DbExecutor.Batch, jobs: []const dbpg.Job) void {
    var statements: [dbpg.BATCH_MAX]?*postgrez.Statement = @splat(null);
    var done: [dbpg.BATCH_MAX]bool = @splat(false);

    // pass 1: cache hits answer directly, everything else resolves its
    // prepared statement on the held connection
    for (jobs, 0..) |job, index| {
        switch (job) {
            .ASYNC_DB => statements[index] = batch.statement(dbpg.slot(.ASYNC_DB), SQL_ASYNC_DB),
            .CRUD_LIST => |request| {
                // an earlier batch may have filled the page after the
                // engine-side miss
                const category = request.category_buf[0..request.category_len];
                const list_key = crudcache.listKey(category, request.page, request.limit);
                if (crudcache.listGetFresh(list_key, &db_body_buf)) |len| {
                    zix.Http1.sendJsonFD(request.fd, 200, db_body_buf[0..len]) catch {};
                    done[index] = true;
                } else {
                    statements[index] = batch.statement(dbpg.slot(.CRUD_LIST), SQL_CRUD_LIST);
                }
            },
            .CRUD_GET => |request| {
                // an earlier batch may have filled the cache after the
                // engine-side miss
                if (crudcache.get(request.id, &db_body_buf)) |len| {
                    sendCrudBody(request.fd, db_body_buf[0..len], "HIT");
                    done[index] = true;
                } else {
                    statements[index] = batch.statement(dbpg.slot(.CRUD_GET), SQL_CRUD_GET);
                }
            },
            .CRUD_CREATE => statements[index] = batch.statement(dbpg.slot(.CRUD_UPSERT), SQL_CRUD_UPSERT),
            .CRUD_UPDATE => statements[index] = batch.statement(dbpg.slot(.CRUD_UPDATE), SQL_CRUD_UPDATE),
        }

        if (!done[index] and statements[index] == null) {
            serviceUnavailable(jobFd(job));
            done[index] = true;
        }
    }

    // pass 2: queue every execution on the held connection
    for (jobs, 0..) |job, index| {
        if (done[index]) continue;

        queueJob(statements[index].?, job) catch |err| {
            failDb(batch, jobFd(job), err);
            done[index] = true;
        };
    }

    // pass 3: results render in sendRows order
    for (jobs, 0..) |job, index| {
        if (done[index]) continue;

        awaitJob(batch, statements[index].?, job);
    }
}

/// Queue one execution (Bind + Execute into the connection send buffer,
/// nothing on the wire yet).
fn queueJob(statement: *postgrez.Statement, job: dbpg.Job) !void {
    switch (job) {
        .ASYNC_DB => |request| try statement.sendRows(.{ request.min, request.max, request.limit }),
        .CRUD_LIST => |request| {
            const category = request.category_buf[0..request.category_len];
            const offset = (request.page - 1) * request.limit;

            try statement.sendRows(.{ category, request.limit, offset });
        },
        .CRUD_GET => |request| try statement.sendRows(.{request.id}),
        .CRUD_CREATE => |request| {
            const name = request.name_buf[0..request.name_len];
            const category = request.category_buf[0..request.category_len];

            try statement.sendRows(.{ request.id, name, category, request.price, request.quantity });
        },
        .CRUD_UPDATE => |request| {
            const name = request.name_buf[0..request.name_len];
            const category = request.category_buf[0..request.category_len];

            try statement.sendRows(.{ request.id, name, category, request.price, request.quantity });
        },
    }
}

/// Take the next queued result, render it, and write the response.
fn awaitJob(batch: *dbpg.DbExecutor.Batch, statement: *postgrez.Statement, job: dbpg.Job) void {
    var result = statement.awaitRows() catch |err| return failDb(batch, jobFd(job), err);
    defer result.deinit();

    switch (job) {
        .ASYNC_DB => |request| {
            const len = renderAsyncDb(&result, &db_body_buf) catch |err| return failDb(batch, request.fd, err);

            zix.Http1.sendJsonFD(request.fd, 200, db_body_buf[0..len]) catch {};
        },
        .CRUD_LIST => |request| {
            const len = renderCrudList(&result, request.page, &db_body_buf) catch |err| return failDb(batch, request.fd, err);

            const category = request.category_buf[0..request.category_len];
            crudcache.listPut(crudcache.listKey(category, request.page, request.limit), db_body_buf[0..len]);
            zix.Http1.sendJsonFD(request.fd, 200, db_body_buf[0..len]) catch {};
        },
        .CRUD_GET => |request| {
            const maybe_len = renderCrudItem(&result, &db_body_buf) catch |err| return failDb(batch, request.fd, err);
            const len = maybe_len orelse return notFound(request.fd);

            finishCrudGet(request.id, db_body_buf[0..len], request.fd);
        },
        .CRUD_CREATE => |request| {
            drainResult(&result) catch |err| return failDb(batch, request.fd, err);

            // The upsert may replace an already-cached row, so a create
            // invalidates too.
            invalidateCrud(request.id);
            zix.Http1.sendSimpleFD(request.fd, 201, "application/json", "{\"status\":\"created\"}") catch {};
        },
        .CRUD_UPDATE => |request| {
            drainResult(&result) catch |err| return failDb(batch, request.fd, err);

            invalidateCrud(request.id);
            zix.Http1.sendSimpleFD(request.fd, 200, "application/json", "{\"status\":\"ok\"}") catch {};
        },
    }
}

/// Drive a row-less result (create/update) to completion so a server error
/// surfaces before the response commits.
fn drainResult(result: *postgrez.Result) !void {
    while (try result.next()) |_| {}
}

/// MISS response plus the two cache fills: the in-process slot and the
/// write-behind Redis mirror.
fn finishCrudGet(id: i64, body: []const u8, fd: std.posix.fd_t) void {
    crudcache.put(id, body);

    if (dbrd.conn()) |cache| {
        var key_buf: [40]u8 = undefined;
        if (std.fmt.bufPrint(&key_buf, CRUD_KEY_PREFIX ++ "{d}", .{id})) |key| {
            cache.setDeferred(key, body, .{ .ex_s = CRUD_CACHE_TTL_S }) catch |err| failCache(err);
        } else |_| {}
    }

    sendCrudBody(fd, body, "MISS");
}
