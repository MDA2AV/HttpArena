//! HttpArena: zix-grpc
//!
//! zix HttpArena gRPC entry point.
//!
//! Intent: demonstrate zix.Grpc (URING dispatch model) against the HttpArena
//! gRPC benchmark suite (unary, server-streaming), cleartext h2c and over TLS.
//!
//! Two listeners run in parallel:
//! - h2c cleartext on PORT (8080) under the .URING dispatch model. Serves unary-grpc and
//!   stream-grpc.
//! - gRPC over TLS 1.3 on H2_TLS_PORT (8443), ALPN h2, with a self-signed Ed25519 cert baked at
//!   /etc/zix-tls. Serves unary-grpc-tls and stream-grpc-tls. The TLS path is the per-core tls_mux
//!   (one worker per core, no thread-per-connection), shared by the .EPOLL and .URING models.
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

// --------------------------------------------------------- //

const PORT: u16 = 8080;
const H2_TLS_PORT: u16 = 8443;
/// Required for ipv4 and ipv6
const LISTEN_IP: []const u8 = "::";
const DISPATCH_MODEL: zix.Grpc.DispatchModel = .URING;
const KERNEL_BACKLOG: u31 = 1024 * 16;
const WORKERS: usize = 0;

// TLS cert / key, a self-signed Ed25519 pair baked at /etc/zix-tls at image build. Overridable via env so the same
// binary runs locally.
const TLS_CERT_DEFAULT: []const u8 = "/etc/zix-tls/server.crt";
const TLS_KEY_DEFAULT: []const u8 = "/etc/zix-tls/server.key";

/// Per-core worker count for .URING (this entry's model) and .EPOLL. 0 selects one worker per CPU,
/// which the shared-nothing io_uring loop wants: the unary path is CPU-bound, so a per-core count
/// tops out throughput while oversubscription only thrashes the scheduler. Keep the default.
const POOL_SIZE: usize = 0;

/// Advertise enough concurrent streams that a client opening many in parallel (h2load uses
/// -m 100) is never refused at startup. Must be >= the load generator's stream count or those
/// streams get REFUSED_STREAM. Per-stream buffers are tiny (below), so a wide table is cheap.
const MAX_STREAMS: usize = 128;

/// gRPC sum messages are a few bytes. A small per-stream body buffer keeps the wide stream
/// table affordable in memory (MAX_STREAMS * MAX_BODY per connection).
const MAX_BODY: usize = 4 * 1024;

// --------------------------------------------------------- //

/// Unary RPC: SumRequest{a, b} -> SumReply{result: a+b}
fn getSumHandler(headers: []const zix.Http2.Header, ctx: *zix.Grpc.Context) void {
    _ = headers;

    const msg = ctx.recvMessage() orelse {
        ctx.finish(.INVALID_ARGUMENT, "empty request");
        return;
    };

    var reader = zix.Grpc.MessageReader.init(msg);
    var req_a: i32 = 0;
    var req_b: i32 = 0;

    while (reader.next() catch null) |field| {
        switch (field.field_number) {
            1 => req_a = @bitCast(@as(u32, @truncate(field.value_u64))),
            2 => req_b = @bitCast(@as(u32, @truncate(field.value_u64))),
            else => {},
        }
    }

    var reply_buf: [16]u8 = undefined;
    const reply_len = zix.Grpc.encodeInt32(1, req_a + req_b, &reply_buf);

    ctx.sendMessage("application/grpc+proto", reply_buf[0..reply_len]);
    ctx.finish(.OK, "");
}

/// Server-streaming RPC: StreamRequest{a, b, count} -> count * SumReply{result: a+b+i}
fn streamSumHandler(headers: []const zix.Http2.Header, ctx: *zix.Grpc.Context) void {
    _ = headers;

    const msg = ctx.recvMessage() orelse {
        ctx.finish(.INVALID_ARGUMENT, "empty request");
        return;
    };

    var reader = zix.Grpc.MessageReader.init(msg);
    var req_a: i32 = 0;
    var req_b: i32 = 0;
    var req_count: i32 = 1;

    while (reader.next() catch null) |field| {
        switch (field.field_number) {
            1 => req_a = @bitCast(@as(u32, @truncate(field.value_u64))),
            2 => req_b = @bitCast(@as(u32, @truncate(field.value_u64))),
            3 => req_count = @bitCast(@as(u32, @truncate(field.value_u64))),
            else => {},
        }
    }

    if (req_count <= 0) req_count = 1;

    const sum = req_a + req_b;
    var reply_buf: [16]u8 = undefined;

    var i: i32 = 0;
    while (i < req_count) : (i += 1) {
        const reply_len = zix.Grpc.encodeInt32(1, sum + i, &reply_buf);
        ctx.sendMessage("application/grpc+proto", reply_buf[0..reply_len]);
    }

    ctx.finish(.OK, "");
}

// --------------------------------------------------------- //

const ROUTES = &[_]zix.Grpc.Route{
    .{ .path = "/benchmark.BenchmarkService/GetSum", .handler = getSumHandler },
    .{ .path = "/benchmark.BenchmarkService/StreamSum", .handler = streamSumHandler, .is_server_streaming = true },
};

// gRPC over TLS 1.3 listener: the per-core tls_mux terminates TLS (ALPN h2) in place (one worker per
// core, no thread-per-connection). A missing or unreadable cert degrades gracefully: this thread
// returns and the cleartext server keeps running.
fn tlsServer(io: std.Io, tls: *zix.Tls.Context) void {
    var server = zix.Grpc.Server.init(ROUTES, .{
        .io = io,
        .ip = LISTEN_IP,
        .port = H2_TLS_PORT,
        .tls = tls,
        .dispatch_model = DISPATCH_MODEL,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_streams = MAX_STREAMS,
        .max_body = MAX_BODY,
    }) catch return;
    defer server.deinit();

    server.run() catch {};
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    // gRPC over TLS on H2_TLS_PORT (ALPN h2) with the baked Ed25519 cert. The cleartext server runs
    // regardless: a missing cert just leaves the TLS port without a listener.
    const cert_path = process.environ_map.get("ARENA_TLS_CERT") orelse TLS_CERT_DEFAULT;
    const key_path = process.environ_map.get("ARENA_TLS_KEY") orelse TLS_KEY_DEFAULT;

    var tls_ctx: ?zix.Tls.Context = zix.Tls.Context.init(std.heap.smp_allocator, process.io, .{
        .cert_path = cert_path,
        .key_path = key_path,
        .alpn = &.{.H2},
        .min_version = .TLS_1_3,
    }) catch null;

    if (tls_ctx) |*tls| {
        _ = std.Thread.spawn(.{}, tlsServer, .{ process.io, tls }) catch {};
    }

    var server = try zix.Grpc.Server.init(ROUTES, .{
        .io = process.io,
        .ip = LISTEN_IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .kernel_backlog = KERNEL_BACKLOG,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
        .max_streams = MAX_STREAMS,
        .max_body = MAX_BODY,
    });
    defer server.deinit();

    try server.run();
}
