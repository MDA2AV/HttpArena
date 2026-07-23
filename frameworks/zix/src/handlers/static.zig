//! GET /static/{file} : serve from /data/static. Picks .br then .gz when the
//! client accepts them, else the plain file. One header send coalesced with
//! a zero-copy sendfile body. Resolved names are cached: open fd, size, and
//! a pre-built header per name.

const std = @import("std");
const zix = @import("zix");

const response = @import("../shared/response.zig");
const encoding = @import("../shared/encoding.zig");

// --------------------------------------------------------- //

pub const PATH = "/static";

/// Static cache name cap. Fixture names are short, anything longer is a 404.
pub const STATIC_NAME_MAX: usize = 96;
/// 20 fixtures times their (.br, .gz, identity) candidates plus headroom.
pub const STATIC_CACHE_MAX: usize = 128;
/// Name index over g_static_entries: name hash to (entry index + 1), 0 =
/// empty. Twice the entry capacity so a probe always ends at its entry or an
/// empty slot. Entries are never removed.
const STATIC_INDEX_SLOTS: usize = STATIC_CACHE_MAX * 2;

var g_static_index: [STATIC_INDEX_SLOTS]u16 = @splat(0);
var g_static_entries: [STATIC_CACHE_MAX]StaticEntry = undefined;
var g_static_count: usize = 0;
var g_static_lock: std.atomic.Value(bool) = .init(false);

pub const g_static_base: []const u8 = "/data/static/";

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

fn staticNameHash(name: []const u8) u64 {
    return std.hash.Wyhash.hash(0, name);
}

fn staticLookup(name: []const u8) ?*const StaticEntry {
    var slot: usize = @intCast(staticNameHash(name) & (STATIC_INDEX_SLOTS - 1));
    while (true) {
        const tag = @atomicLoad(u16, &g_static_index[slot], .acquire);
        if (tag == 0) return null;

        const entry = &g_static_entries[tag - 1];
        if (std.mem.eql(u8, entry.name_buf[0..entry.name_len], name)) return entry;

        slot = (slot + 1) & (STATIC_INDEX_SLOTS - 1);
    }
}

fn openStatic(name: []const u8) ?std.posix.fd_t {
    var path_buf: [512]u8 = undefined;
    const file_path =
        std.fmt.bufPrint(&path_buf, "{s}{s}", .{ g_static_base, name }) catch
            return null;
    if (file_path.len >= path_buf.len) return null;

    path_buf[file_path.len] = 0;

    return std.posix.openatZ(std.posix.AT.FDCWD, @ptrCast(&path_buf), .{ .ACCMODE = .RDONLY }, 0) catch null;
}

fn buildVariant(name: []const u8) ?StaticVariant {
    const file_fd = openStatic(name) orelse return null;

    var stx: std.os.linux.Statx = undefined;
    const stat_rc =
        std.os.linux.statx(file_fd, "", std.os.linux.AT.EMPTY_PATH, .{ .SIZE = true }, &stx);
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

fn staticInsert(name: []const u8) ?*const StaticEntry {
    while (g_static_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
    defer g_static_lock.store(false, .release);

    if (staticLookup(name)) |e| return e;
    const count = @atomicLoad(usize, &g_static_count, .acquire);
    if (count == STATIC_CACHE_MAX) return null;

    const e = &g_static_entries[count];
    e.name_len = @intCast(name.len);
    @memcpy(e.name_buf[0..name.len], name);
    e.variant = buildVariant(name);
    @atomicStore(usize, &g_static_count, count + 1, .release);

    // Publish the index slot last (release), so a lock-free reader that sees
    // the slot always sees the finished entry bytes behind it.
    var slot: usize = @intCast(staticNameHash(name) & (STATIC_INDEX_SLOTS - 1));
    while (@atomicLoad(u16, &g_static_index[slot], .monotonic) != 0)
        slot = (slot + 1) & (STATIC_INDEX_SLOTS - 1);
    @atomicStore(u16, &g_static_index[slot], @intCast(count + 1), .release);

    return e;
}

fn contentType(rel: []const u8) []const u8 {
    const ext = std.fs.path.extension(rel);
    const ext_no_dot = if (ext.len > 0) ext[1..] else ext;

    return zix.Http1.Content.fromExtension(ext_no_dot);
}

fn waitWritable(fd: std.posix.fd_t) error{BrokenPipe}!void {
    var pfd =
        [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};

    _ = std.posix.poll(&pfd, -1) catch return error.BrokenPipe;
}

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

// --------------------------------------------------------- //

pub fn resolveStatic(name: []const u8) ?*const StaticEntry {
    const entry = staticLookup(name) orelse staticInsert(name) orelse return null;
    if (entry.variant == null) return null;

    return entry;
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

pub fn RESPONSE(req: *zix.Http1.Request, _: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    const head = req.head;
    const fd = req.fd;

    // The PREFIX route also matches a bare /static (no trailing slash), which
    // would slice out of bounds below.
    if (head.path.len < "/static/".len) return response.notFound(fd);

    const rel = head.path["/static/".len..];
    if (rel.len == 0 or
        rel.len > STATIC_NAME_MAX or
        std.mem.indexOf(u8, rel, "..") != null or
        rel[0] == '/') return response.notFound(fd);

    const accept = encoding.accept(head);

    // Candidates "{rel}.br" / "{rel}.gz" / "{rel}".
    var cand_buf: [STATIC_NAME_MAX + 3]u8 = undefined;
    var entry: ?*const StaticEntry = null;

    if (accept.prefers_br) {
        const cand =
            std.fmt.bufPrint(&cand_buf, "{s}.br", .{rel}) catch
                return response.notFound(fd);
        entry = resolveStatic(cand);
    }
    if (entry == null and accept.accepts_gzip) {
        const cand = std.fmt.bufPrint(&cand_buf, "{s}.gz", .{rel}) catch
            return response.notFound(fd);
        entry = resolveStatic(cand);
    }
    if (entry == null) {
        entry = resolveStatic(rel);
    }

    const served = entry orelse return response.notFound(fd);
    const variant: *const StaticVariant =
        if (served.variant) |*v| v else return response.notFound(fd);

    // Raw fd writes below: flush engine-staged responses first so the wire
    // order matches the request order under pipelining.
    zix.Http1.flushPending(fd);

    sendMoreFD(fd, variant.hdr_buf[0..variant.hdr_len]) catch return;
    sendfileAll(fd, variant.fd, variant.size) catch {};
}
