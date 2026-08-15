//! benchmark.BenchmarkService/StreamSum : server-streaming
//! StreamRequest{a, b, count} -> count replies of SumReply{a + b + i}.
//!
//! Note:
//! - Every reply is encoded in the loop. Nothing is cached, and the replies are
//!   not identical, so there would be nothing to reuse anyway.

const std = @import("std");
const zix = @import("zix");

const sumrequest = @import("../shared/sumrequest.zig");

// --------------------------------------------------------- //

pub const PATH = "/benchmark.BenchmarkService/StreamSum";

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
    const sum = call.sum();
    const replies = call.replies();

    var reply_buf: [REPLY_BUF]u8 = undefined;
    var index: i32 = 0;
    while (index < replies) : (index += 1) {
        const reply_len = zix.Grpc.encodeInt32(1, sum +% index, &reply_buf);

        try res.sendMessage(CONTENT_TYPE, reply_buf[0..reply_len]);
    }

    try res.finish(.OK, "");
}
