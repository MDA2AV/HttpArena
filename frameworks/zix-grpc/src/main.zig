//! HttpArena: zix-grpc
//!
//! zix HttpArena gRPC entry point.
//!
//! Intent: demonstrate zix.Grpc (URING dispatch model) against the HttpArena
//! gRPC benchmark suite (unary, server-streaming), cleartext h2c and over TLS.
//!
//! ONE server, two listeners through config.tls_port (dual listener):
//! - h2c cleartext on PORT (8080). Serves unary-grpc and stream-grpc.
//! - gRPC over TLS 1.3 on TLS_PORT (8443), ALPN h2, self-signed Ed25519 cert
//!   baked at /etc/zix-tls, terminated on the same per-core .URING workers
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

// --------------------------------------------------------- //

const IP: []const u8 = "::";
const PORT: u16 = 8080;
const DISPATCH_MODEL: zix.Grpc.DispatchModel = .URING;

const WORKERS: usize = 0;

const TLS_PORT: u16 = 8443;
const TLS_CERT_DEFAULT: []const u8 = "/etc/zix-tls/server.crt";
const TLS_KEY_DEFAULT: []const u8 = "/etc/zix-tls/server.key";

const KERNEL_BACKLOG: u31 = 16 * 1024;

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

const Routes = &[_]zix.Grpc.Route{
    .{ .path = "/benchmark.BenchmarkService/GetSum", .handler = getSumHandler },
    .{ .path = "/benchmark.BenchmarkService/StreamSum", .handler = streamSumHandler, .is_server_streaming = true },
};

pub fn main(process: std.process.Init) !void {
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

    var server = zix.Grpc.Server.init(Routes, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .tls = &tls,
        .tls_port = TLS_PORT,
        .dispatch_model = DISPATCH_MODEL,
        .kernel_backlog = KERNEL_BACKLOG,
    });
    defer server.deinit();

    try server.run();
}
