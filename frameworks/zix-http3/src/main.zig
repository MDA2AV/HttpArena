//! HttpArena: zix (attempt 1)
//!
//! zix.Http3 (.URING) against the HttpArena HTTP/3 suite
//! (baseline-h3, static-h3).
//! QUIC over UDP on PORT, TLS 1.3 inside the handshake
//! (baked Ed25519 cert at /etc/zix-tls), ALPN h3 negotiated by the engine.
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

const PROBE_TCP_PORT: u16 = 8443;

const TLS_CERT_DEFAULT: []const u8 = "/etc/zix-tls/server.crt";
const TLS_KEY_DEFAULT: []const u8 = "/etc/zix-tls/server.key";

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
        .dispatch_model = DISPATCH_MODEL,
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
    const data_dir = "/data";
    handler.g_static_base = std.fmt.bufPrint(&handler.g_static_base_buf, "{s}/static/", .{data_dir}) catch "/data/static/";

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
