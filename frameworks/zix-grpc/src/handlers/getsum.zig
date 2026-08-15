//! benchmark.BenchmarkService/GetSum : unary SumRequest{a, b} -> SumReply{a + b}.
//!
//! Note:
//! - Nothing is cached. The compute is one add and the reply is a few bytes,
//!   well under any cache crossover, so a lookup would cost more than the work.

const std = @import("std");
const zix = @import("zix");

const sumrequest = @import("../shared/sumrequest.zig");

// --------------------------------------------------------- //

pub const PATH = "/benchmark.BenchmarkService/GetSum";

/// One SumReply: a field tag plus a varint, so 16 bytes is ample.
const REPLY_BUF: usize = 16;

const CONTENT_TYPE = "application/grpc+proto";

// --------------------------------------------------------- //

pub fn RESPONSE(req: *zix.Grpc.Request, res: *zix.Grpc.Response, _: *zix.Grpc.Context) !void {
    const msg = req.recvMessage() orelse {
        try res.finish(.INVALID_ARGUMENT, "empty request");
        return;
    };

    const call = sumrequest.decode(msg);

    var reply_buf: [REPLY_BUF]u8 = undefined;
    const reply_len = zix.Grpc.encodeInt32(1, call.sum(), &reply_buf);

    try res.sendMessage(CONTENT_TYPE, reply_buf[0..reply_len]);
    try res.finish(.OK, "");
}
