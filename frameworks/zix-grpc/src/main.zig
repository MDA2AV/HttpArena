//! HttpArena: zix-grpc
//!
//! zix HttpArena gRPC (h2c) entry point.
//!
//! Intent: demonstrate zix.Grpc (EPOLL dispatch model) against the HttpArena
//! gRPC benchmark suite (unary, server-streaming).
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
/// Required for ipv4 and ipv6
const LISTEN_IP: []const u8 = "::";
const DISPATCH_MODEL: zix.Grpc.DispatchModel = .EPOLL;
const KERNEL_BACKLOG: u31 = 1024 * 16;
const WORKERS: usize = 0;

/// 0 selects the engine default EPOLL pool (max(10, cpu*2)). Each worker owns one connection
/// while it is active. After the Phase 1 syscall cuts the unary path is CPU-bound, not
/// connection-bound: a modest cpu-relative pool tops out throughput, while an oversized pool
/// (thread-per-connection) thrashes the scheduler and collapses it. So keep the default.
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

pub fn main(process: std.process.Init) !void {
    var server = try zix.Grpc.Server.init(&[_]zix.Grpc.Route{
        .{ .path = "/benchmark.BenchmarkService/GetSum", .handler = getSumHandler },
        .{ .path = "/benchmark.BenchmarkService/StreamSum", .handler = streamSumHandler, .is_server_streaming = true },
    }, .{
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
