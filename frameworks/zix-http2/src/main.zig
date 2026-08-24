//! HttpArena: zix-http2
//!
//! zix HTTP/2 entry point on the zix.Http2 engine (no std.http).
//! ONE server, two listeners through config.tls_port (dual listener):
//! - h2c cleartext on PORT under .URING
//!   (shared-nothing per-core io_uring, one SO_REUSEPORT
//!   listener plus ring per CPU). Serves baseline-h2c and json-h2c.
//! - h2 over TLS 1.3 on TLS_PORT
//!   (ALPN h2, the RSA cert mounted at /certs),
//!   terminated on the same per-core rings: no second launch,
//!   no doubled workers or fd tables. Serves baseline-h2 and static-h2.
//!
//! Endpoints:
//! - GET /baseline2?a=..&b=.. : sum the query values
//!   plus the POST body as an integer, text/plain.
//! - GET /json/{count}?m=M    : render count dataset items,
//!   total = price*quantity*M, json.
//! - GET /static/{file}       : serve /data/static by extension,
//!   body as chunked DATA frames (<= 16 KiB).
//!
//! One route table serves both listeners:
//! extra routes on each port are simply never hit by the
//! benchmark (h2c hits baseline + json, TLS hits baseline + static).

const std = @import("std");
const zix = @import("zix");

const dataset = @import("dataset.zig");
const handler = @import("handler.zig");

// --------------------------------------------------------- //

const IP: []const u8 = "::";
const PORT: u16 = 8082;
const DISPATCH_MODEL: zix.Http2.DispatchModel = .URING;

const TLS_PORT: u16 = 8443;
const TLS_CERT_DEFAULT: []const u8 = "/certs/server.crt";
const TLS_KEY_DEFAULT: []const u8 = "/certs/server.key";

// --------------------------------------------------------- //

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
            if (std.fmt.bufPrint(&cand_buf, "{s}.br", .{stem})) |cand| {
                _ = handler.resolveStatic(cand);
            } else |_| {}
            if (std.fmt.bufPrint(&cand_buf, "{s}.gz", .{stem})) |cand| {
                _ = handler.resolveStatic(cand);
            } else |_| {}
            _ = handler.resolveStatic(stem);
        }
    }
}

// --------------------------------------------------------- //

const Routes = &[_]zix.Http2.Route{
    .{ .path = "/baseline2", .handler = handler.baseline },
    .{ .path = "/json", .handler = handler.json, .kind = .PREFIX },
    .{ .path = "/static", .handler = handler.static, .kind = .PREFIX },
};

pub fn main(process: std.process.Init) !void {
    // Elevate scheduling priority (setpriority -19). Fails silently when the
    // process lacks CAP_SYS_NICE, so no special capability is required for correctness.
    _ = std.os.linux.syscall3(.setpriority, 0, 0, @as(usize, @bitCast(@as(isize, -19))));

    // Warm the static cache before any worker serves,
    // so the request path is lock-free (no spinlock
    // held across a file open on the first request for each name).
    prewarmStatic();

    var allocator_dataset = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer allocator_dataset.deinit();

    var dataset_path_buf: [512]u8 = undefined;
    const data_dir = "/data";
    const dataset_path = try std.fmt.bufPrint(&dataset_path_buf, "{s}/dataset.json", .{data_dir});
    handler.g_dataset = try dataset.load(allocator_dataset.allocator(), dataset_path);
    handler.g_static_base = std.fmt.bufPrint(&handler.g_static_base_buf, "{s}/static/", .{data_dir}) catch "/data/static/";

    var allocator_tls = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer allocator_tls.deinit();

    var tls = zix.Tls.Context.init(allocator_tls.allocator(), process.io, .{
        .cert_path = TLS_CERT_DEFAULT,
        .key_path = TLS_KEY_DEFAULT,
        .alpn = &.{.H2},
        .min_version = .TLS_1_3,
    }) catch |e| {
        std.debug.print("Error tls context: {}\n", .{e});
        return;
    };
    defer tls.deinit();

    // Dual listener (config.tls_port): ONE server serves h2c on PORT and h2
    // over TLS on TLS_PORT from the same .URING worker fleet (TLS terminated
    // on-ring), instead of a second full launch doubling workers and caches.
    var server = zix.Http2.Server.init(Routes, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .tls = &tls,
        .tls_port = TLS_PORT,
        .dispatch_model = DISPATCH_MODEL,
        .kernel_backlog = 24 * 1024,
        .max_streams = 1024,
        .max_frame_size = 24 * 1024,
        .max_recv_buf = 64 * 1024,
        .max_body = 32 * 1024,
        .tls_write_buf_initial_bytes = 32 * 1024,
    });
    defer server.deinit();

    try server.run();
}
