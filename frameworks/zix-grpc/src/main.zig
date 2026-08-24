//! HttpArena: zix-grpc
//!
//! zix HttpArena gRPC entry point.
//!
//! Intent: demonstrate zix.Grpc (URING dispatch model) against the HttpArena
//! gRPC benchmark suite (unary, server-streaming), cleartext h2c and over TLS.
//!
//! ONE server, two listeners through config.tls_port (dual listener):
//! - h2c cleartext on PORT (8080). Serves unary-grpc and stream-grpc.
//! - gRPC over TLS 1.3 on TLS_PORT (8443), ALPN h2, the shared RSA cert
//!   mounted at /certs, terminated on the same per-core .URING workers
//!   (no second launch, no doubled workers or fd tables).
//!   Serves unary-grpc-tls and stream-grpc-tls.
//!
//! Design choices:
//! - GetSum: unary SumRequest{a, b} -> SumReply{a + b}. The compute is a single
//!   add and the reply is a few bytes, well below the response-cache crossover,
//!   so caching would cost more than it saves and stays off here.
//! - StreamSum: server-streaming, count replies of a + b + i.
//! - max_streams is wide enough that a client opening many parallel streams is
//!   never refused at startup.

const std = @import("std");
const zix = @import("zix");

const getsum = @import("handlers/getsum.zig");
const streamsum = @import("handlers/streamsum.zig");

const paths = @import("shared/paths.zig");

// --------------------------------------------------------- //

const Routes = zix.Grpc.Router(&[_]zix.Grpc.Route{
    .{ .path = getsum.PATH, .handler = getsum.RESPONSE },
    .{ .path = streamsum.PATH, .handler = streamsum.RESPONSE, .is_server_streaming = true },
});

pub fn main(process: std.process.Init) !void {
    var allocator_tls = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer allocator_tls.deinit();

    var tls = zix.Tls.Context.init(allocator_tls.allocator(), process.io, .{
        .cert_path = paths.TLS_CERT,
        .key_path = paths.TLS_KEY,
        .alpn = &.{.H2},
        .min_version = .TLS_1_3,
    }) catch |e| {
        return e;
    };
    defer tls.deinit();

    var server = zix.Grpc.Server.init(Routes, .{
        .io = process.io,
        .ip = "::",
        .port = 8080,
        .tls = &tls,
        .tls_port = 8443,
        .dispatch_model = .URING,
        //
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
