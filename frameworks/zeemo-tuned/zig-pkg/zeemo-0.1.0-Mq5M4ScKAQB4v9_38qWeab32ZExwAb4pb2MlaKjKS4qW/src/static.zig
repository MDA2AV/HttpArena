//! Static file cache: user names the files + content-types it wants
//! served, the library reads them, optionally picks up `.br` and `.gz`
//! pre-compressed siblings on disk, and pre-bakes the full HTTP/1.1
//! response for each variant. The handler then dispatches the matching
//! pre-baked bytes per request based on `Accept-Encoding` — zero copy
//! in the hot path.
//!
//! What the user wants served (filenames, content-types, which extensions
//! to look for) is a property of the application, not the framework, so
//! it stays in the calling code. The library handles the I/O plumbing,
//! the response baking, and the request-time variant selection.

const std = @import("std");
const linux = std.os.linux;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const router_module = @import("router.zig");

pub const FileEntry = struct {
    plain: []const u8,
    br: ?[]const u8 = null,
    gz: ?[]const u8 = null,
};

pub const AddOpts = struct {
    /// When true, look for `<name>.br` and `<name>.gz` siblings in `fs_root`
    /// and pre-bake encoded variants. Skip for already-compressed formats
    /// like woff2 and webp where the .br/.gz files wouldn't exist anyway.
    compressible: bool = false,
};

pub const Dir = struct {
    gpa: std.mem.Allocator,
    fs_root: []const u8,
    map: std.StringHashMap(FileEntry),
    arena: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator, fs_root: []const u8) Dir {
        return .{
            .gpa = gpa,
            .fs_root = fs_root,
            .map = std.StringHashMap(FileEntry).init(gpa),
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(self: *Dir) void {
        self.map.deinit();
        self.arena.deinit();
    }

    /// Read `<fs_root>/<name>` (and optionally its .br/.gz siblings) and
    /// pre-bake response variants. The key in the lookup map is the
    /// caller-supplied `name` slice — duplicated into the arena so it's
    /// owned by the Dir.
    pub fn add(self: *Dir, name: []const u8, content_type: []const u8, opts: AddOpts) !void {
        const aa = self.arena.allocator();
        const plain_body = try readFile(aa, self.fs_root, name, "");
        const baked_plain = try bake(aa, content_type, null, plain_body);
        var entry: FileEntry = .{ .plain = baked_plain };

        if (opts.compressible) {
            if (try maybeReadFile(aa, self.fs_root, name, ".br")) |b|
                entry.br = try bake(aa, content_type, "br", b);
            if (try maybeReadFile(aa, self.fs_root, name, ".gz")) |g|
                entry.gz = try bake(aa, content_type, "gzip", g);
        }
        const name_dup = try aa.dupe(u8, name);
        try self.map.put(name_dup, entry);
    }
};

/// Pointer to the active Dir, set once at startup. Allows the static
/// handler — which has a fixed `fn(*Request, *Response)` signature
/// dictated by the router — to find the per-process cache without a
/// closure or capture.
var bound_dir: ?*const Dir = null;

pub fn setDir(d: *const Dir) void {
    bound_dir = d;
}

pub fn handler(req: *const Request, res: *Response) anyerror!void {
    const dir = bound_dir orelse {
        res.status(503);
        try res.text("static dir not configured");
        return;
    };
    const slash = std.mem.lastIndexOfScalar(u8, req.path, '/') orelse {
        res.status(404);
        try res.text("Not Found");
        return;
    };
    const name = req.path[slash + 1 ..];
    const entry = dir.map.get(name) orelse {
        res.status(404);
        try res.text("Not Found");
        return;
    };
    const picked = if (req.accepts_br)
        (entry.br orelse entry.plain)
    else if (req.accepts_gzip)
        (entry.gz orelse entry.plain)
    else
        entry.plain;
    res.sendPreBaked(picked);
}

pub fn registerHandler() router_module.HandlerFn {
    return &handler;
}

fn readFile(aa: std.mem.Allocator, fs_root: []const u8, name: []const u8, suffix: []const u8) ![]u8 {
    if (try readFileImpl(aa, fs_root, name, suffix)) |b| return b;
    return error.FileNotFound;
}

fn maybeReadFile(aa: std.mem.Allocator, fs_root: []const u8, name: []const u8, suffix: []const u8) !?[]u8 {
    return readFileImpl(aa, fs_root, name, suffix);
}

fn readFileImpl(aa: std.mem.Allocator, fs_root: []const u8, name: []const u8, suffix: []const u8) !?[]u8 {
    var path_buf: [std.posix.PATH_MAX]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}{s}\x00", .{ fs_root, name, suffix }) catch
        return error.PathTooLong;
    const path_z: [*:0]const u8 = @ptrCast(path.ptr);

    const rc = linux.openat(linux.AT.FDCWD, path_z, .{ .ACCMODE = .RDONLY }, 0);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .NOENT => return null,
        else => return error.OpenFailed,
    }
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(aa);
    while (true) {
        try buf.ensureUnusedCapacity(aa, 32 * 1024);
        const dst = buf.unusedCapacitySlice();
        const n = std.posix.read(fd, dst) catch return error.ReadFailed;
        if (n == 0) break;
        buf.items.len += n;
    }
    return try buf.toOwnedSlice(aa);
}

/// Compose `<status line><headers><body>` into a contiguous arena-owned
/// buffer and return the slice ready to send.
fn bake(aa: std.mem.Allocator, content_type: []const u8, encoding: ?[]const u8, body: []const u8) ![]const u8 {
    var enc_hdr: [64]u8 = undefined;
    const enc_str: []const u8 = if (encoding) |enc|
        std.fmt.bufPrint(&enc_hdr, "Content-Encoding: {s}\r\n", .{enc}) catch return error.BakeOverflow
    else
        @as([]const u8, "");
    var hdr_buf: [256]u8 = undefined;
    const hdr = try std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n{s}\r\n",
        .{ content_type, body.len, enc_str },
    );
    const total = try aa.alloc(u8, hdr.len + body.len);
    @memcpy(total[0..hdr.len], hdr);
    @memcpy(total[hdr.len..], body);
    return total;
}
