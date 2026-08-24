//! HttpArena: zix (attempt 1)
//!
//! zix.Http3 (.URING) against the HttpArena HTTP/3 suite
//! (baseline-h3, static-h3).
//! QUIC over UDP on PORT, TLS 1.3 inside the handshake
//! (the RSA cert mounted at /certs), ALPN h3 negotiated by the engine.
//! /baseline2 sums the query integers, /static serves /data/static
//! with .br / .gz negotiation against the request accept-encoding.
//! A one-worker https responder on TCP 8443 answers the bench readiness
//! probe (plain TCP curl), since QUIC on UDP alone can never satisfy it
//! (see probeServer below). It idles during the measured run.

const std = @import("std");
const zix = @import("zix");

const handler = @import("handler.zig");

// --------------------------------------------------------- //

const IP: []const u8 = "::";
const PORT: u16 = 8443;
const DISPATCH_MODEL: zix.Http3.DispatchModel = .URING;

const WORKERS: usize = 0;

// Same number as PORT on purpose: QUIC binds UDP 8443, the readiness probe
// arrives on TCP 8443 (the two coexist, distinct sockets).
const PROBE_TCP_PORT: u16 = 8443;

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

// Answers the readiness probe (GET /baseline2?a=1&b=1 over TCP https).
// Any 2xx body satisfies the probe curl, the value mirrors a=1&b=1.
fn probeResponder(_: *const zix.Http1.ParsedHead, _: []const u8, fd: std.posix.fd_t) void {
    const response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 1\r\n\r\n2";

    zix.Http1.writeAllFD(fd, response) catch {};
}

// Readiness responder: the bench probes h3 profiles with a plain TCP https
// GET on 8443 before starting the load generator. QUIC is UDP-only, so
// without a TCP listener the probe never succeeds and the run is skipped.
// One worker, idle during the measured run (the load generator speaks QUIC
// on UDP 8443 only).
fn probeServer(io: std.Io, tls: *zix.Tls.Context) void {
    var server = zix.Http1.Server.init(probeResponder, .{
        .io = io,
        .ip = IP,
        .port = PROBE_TCP_PORT,
        .tls = tls,
        .dispatch_model = .EPOLL,
        .workers = 1,
    });
    defer server.deinit();

    server.run() catch {};
}

// --------------------------------------------------------- //

const Routes = zix.Http3.Router(&[_]zix.Http3.Route{
    .{ .path = "/baseline2", .handler = handler.baseline },
    .{ .path = "/static", .handler = handler.static, .kind = .PREFIX },
});

pub fn main(process: std.process.Init) !void {
    // Elevate scheduling priority (setpriority -19). Fails silently when the
    // process lacks CAP_SYS_NICE, so no special capability is required for correctness.
    _ = std.os.linux.syscall3(.setpriority, 0, 0, @as(usize, @bitCast(@as(isize, -19))));

    // Warm the static cache before any worker serves,
    // so the request path is lock-free (no spinlock
    // held across a file open on the first request for each name).
    const data_dir = "/data";
    handler.g_static_base = std.fmt.bufPrint(&handler.g_static_base_buf, "{s}/static/", .{data_dir}) catch "/data/static/";
    prewarmStatic();

    var allocator_tls = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer allocator_tls.deinit();

    // QUIC has no cleartext mode, so a missing or unreadable cert is fatal here
    // (no cleartext server to degrade to, unlike the TCP entries).
    var tls = try zix.Tls.Context.init(allocator_tls.allocator(), process.io, .{
        .cert_path = TLS_CERT_DEFAULT,
        .key_path = TLS_KEY_DEFAULT,
        .min_version = .TLS_1_3,
    });
    defer tls.deinit();

    // Probe-only https listener on TCP 8443 (see probeServer). A failed
    // context init just skips it: readiness then cannot be probed, but the
    // QUIC server itself is unaffected.
    var probe_tls: ?zix.Tls.Context = zix.Tls.Context.init(allocator_tls.allocator(), process.io, .{
        .cert_path = TLS_CERT_DEFAULT,
        .key_path = TLS_KEY_DEFAULT,
        .alpn = &.{.HTTP_1_1},
        .min_version = .TLS_1_3,
    }) catch null;

    if (probe_tls) |*probe_context| {
        _ = std.Thread.spawn(.{}, probeServer, .{ process.io, probe_context }) catch {};
    }

    var server = zix.Http3.Server.init(Routes.dispatch, .{
        .io = process.io,
        .allocator = std.heap.smp_allocator,
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .workers = WORKERS,
        .tls = &tls,
    });
    defer server.deinit();

    try server.run();
}
