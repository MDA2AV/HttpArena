//! Decoding for the two request messages both RPCs share.
//!
//! Note:
//! - SumRequest and StreamRequest differ only by the trailing count field, so
//!   one reader covers both: a SumRequest simply leaves count at its default.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

/// benchmark.SumRequest {a = 1, b = 2} and benchmark.StreamRequest, which adds
/// {count = 3}.
pub const SumRequest = struct {
    a: i32 = 0,
    b: i32 = 0,
    count: i32 = 1,

    pub fn sum(self: SumRequest) i32 {
        return self.a +% self.b;
    }

    /// Replies a server-streaming call should emit. Always at least one, so a
    /// missing or non-positive count still produces a well-formed stream.
    pub fn replies(self: SumRequest) i32 {
        return if (self.count <= 0) 1 else self.count;
    }
};

// --------------------------------------------------------- //

/// Read the proto3 fields out of one gRPC message body.
///
/// Note:
/// - An unreadable field ends the scan, leaving the fields decoded so far. The
///   benchmark messages are a few bytes of varints, so there is nothing to
///   recover past a malformed one.
///
/// Param:
/// msg - []const u8 (one gRPC message, length prefix already stripped)
///
/// Return:
/// - SumRequest
pub fn decode(msg: []const u8) SumRequest {
    var out: SumRequest = .{};

    var reader = zix.Grpc.MessageReader.init(msg);
    while (reader.next() catch null) |field| {
        const value: i32 = @bitCast(@as(u32, @truncate(field.value_u64)));

        switch (field.field_number) {
            1 => out.a = value,
            2 => out.b = value,
            3 => out.count = value,
            else => {},
        }
    }

    return out;
}
