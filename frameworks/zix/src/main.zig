//! HttpArena: zix
//!
//! zix.Http1 (.URING) against the HttpArena HTTP/1.1 suite
//! (baseline, pipelined, limited-conn, json, json-comp, upload, static).
//! json-comp reuses /json and gzips on Accept-Encoding: gzip. json-tls
//! runs a second Http1 server on H1TLS_PORT
//! (https over TLS 1.3, baked Ed25519 cert, per-core tls_mux).
//! /pipeline is fast-pathed in rawIntercept (see below),
//! other routes go through the comptime Router.

const std = @import("std");
const zix = @import("zix");

const dataset = @import("dataset.zig");
const handler = @import("handler.zig");

// --------------------------------------------------------- //

const IP: []const u8 = "::";
const PORT: u16 = 8080;
const DISPATCH_MODEL: zix.Http1.DispatchModel = .URING;

const MAX_HEADERS: u8 = 8;
const WORKERS: usize = 0;

const SEND_DATE_HEADER: bool = false;
const RESPONSE_CACHE: bool = true;
const CACHE_MAX_ENTRIES: u32 = 64;
const CACHE_MAX_VALUE_BYTES: u32 = 32 * 1024;

const TLS_PORT: u16 = 8081;
const TLS_CERT_DEFAULT: []const u8 = "/etc/zix-tls/server.crt";
const TLS_KEY_DEFAULT: []const u8 = "/etc/zix-tls/server.key";

const KERNEL_BACKLOG: u31 = 16 * 1024;

// --------------------------------------------------------- //

// json-tls https server on TLS_PORT. Under .EPOLL / .URING
// it terminates TLS in the per-core
// tls_mux (one worker per core, bounded memory),
// which scales where the thread-per-connection path melts down.
// The same Router dispatch serves the handlers (json-tls only exercises /json).
fn tlsWorker(io: std.Io, tls: *zix.Tls.Context) void {
    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = io,
        .ip = IP,
        .port = TLS_PORT,
        .tls = tls,
        .dispatch_model = DISPATCH_MODEL,
        .workers = WORKERS,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_headers = MAX_HEADERS,
        .send_date_header = false,
    });
    defer server.deinit();

    server.run() catch {};
}

/// Populate the static cache once at startup,
/// single-threaded, warming every candidate the handler probes (.br, .gz, identity)
/// so the request path only hits the lock-free lookup.
/// Without it the first request for each name inserts
/// under the spinlock while opening the file.
fn prewarmStatic() void {
    var base_buf: [512]u8 = undefined;
    var base = handler.g_static_base;
    if (base.len > 1 and base[base.len - 1] == '/') base = base[0 .. base.len - 1];
    if (base.len >= base_buf.len) return;

    @memcpy(base_buf[0..base.len], base);
    base_buf[base.len] = 0;

    const dir_fd = std.posix.openatZ(std.posix.AT.FDCWD, @ptrCast(&base_buf), .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0) catch return;
    defer _ = std.posix.system.close(dir_fd);

    // Iterate with raw getdents64 (this std.fs has no portable Dir.iterate).
    // linux_dirent64 layout:
    // d_ino(8) d_off(8) d_reclen(2 @16) d_type(1 @18) d_name(@19, null-terminated).
    var dbuf: [4096]u8 = undefined;
    while (true) {
        const rc = std.os.linux.getdents64(dir_fd, &dbuf, dbuf.len);
        const got: isize = @bitCast(rc);
        if (got <= 0) break;

        var off: usize = 0;
        while (off < @as(usize, @intCast(got))) {
            const reclen: usize = @as(usize, dbuf[off + 16]) | (@as(usize, dbuf[off + 17]) << 8);
            const d_type = dbuf[off + 18];
            const name = std.mem.sliceTo(dbuf[off + 19 ..], 0);
            off += reclen;

            if (d_type == 4) continue; // DT_DIR
            if (name.len == 0 or name[0] == '.') continue;

            // Reduce a precompressed name to its base,
            // then warm every candidate (.br, .gz, identity).
            // A missing variant caches a null slot,
            // so the request path never inserts under load.
            var stem = name;
            if (std.mem.endsWith(u8, stem, ".br")) stem = stem[0 .. stem.len - ".br".len] else if (std.mem.endsWith(u8, stem, ".gz")) stem = stem[0 .. stem.len - ".gz".len];
            if (stem.len == 0 or stem.len > handler.STATIC_NAME_MAX) continue;

            var cand_buf: [handler.STATIC_NAME_MAX + 3]u8 = undefined;
            if (std.fmt.bufPrint(&cand_buf, "{s}.br", .{stem})) |c| {
                _ = handler.resolveStatic(c);
            } else |_| {}
            if (std.fmt.bufPrint(&cand_buf, "{s}.gz", .{stem})) |c| {
                _ = handler.resolveStatic(c);
            } else |_| {}
            _ = handler.resolveStatic(stem);
        }
    }
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/baseline11", .handler = handler.baseline },
    .{ .path = "/pipeline", .handler = handler.pipeline },
    .{ .path = "/upload", .handler = handler.upload },
    .{ .path = "/json", .handler = handler.jsonResp, .kind = .PREFIX },
    .{ .path = "/static", .handler = handler.static, .kind = .PREFIX },
});

pub fn main(process: std.process.Init) !void {
    // Elevate scheduling priority (setpriority -19). Fails silently when the
    // process lacks CAP_SYS_NICE, so no special capability is required for correctness.
    _ = std.os.linux.syscall3(.setpriority, 0, 0, @as(usize, @bitCast(@as(isize, -19))));

    // Warm the static cache before any worker serves,
    // so the request path is lock-free (no spinlock
    // held across a file open on the first request for each name).
    prewarmStatic();

    var alloc_dataset = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer alloc_dataset.deinit();

    var dataset_path_buf: [512]u8 = undefined;
    const data_dir = "/data";
    const dataset_path = try std.fmt.bufPrint(&dataset_path_buf, "{s}/dataset.json", .{data_dir});
    handler.g_dataset = try dataset.load(alloc_dataset.allocator(), dataset_path);
    handler.g_static_base = std.fmt.bufPrint(&handler.g_static_base_buf, "{s}/static/", .{data_dir}) catch "/data/static/";

    var allocator_tls = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer allocator_tls.deinit();

    var tls_ctx: ?zix.Tls.Context = zix.Tls.Context.init(allocator_tls.allocator(), process.io, .{
        .cert_path = TLS_CERT_DEFAULT,
        .key_path = TLS_KEY_DEFAULT,
        .alpn = &.{.HTTP_1_1},
        .min_version = .TLS_1_3
    }) catch null;

    if (tls_ctx) |*tls| {
        // One TLS server thread:
        // It spawn it's own /core tls_mux worker internally,
        // so a thread pool here would over-subscribe. Thread models use one accept loop
        _ = std.Thread.spawn(.{}, tlsWorker, .{process.io, tls}) catch {};
    }

    var server = zix.Http1.Server.initRaw(Routes.dispatch, handler.rawIntercept, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .max_headers = MAX_HEADERS,
        .workers = WORKERS,
        .send_date_header = SEND_DATE_HEADER,
        .response_cache = RESPONSE_CACHE,
        .cache_max_entries = CACHE_MAX_ENTRIES,
        .cache_max_value_bytes = CACHE_MAX_VALUE_BYTES,
        .cache_ttl_ms = handler.CACHE_TTL_MS,
    });
    defer server.deinit();

    try server.run();
}
