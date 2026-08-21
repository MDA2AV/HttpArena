//! Byte-buffer appenders shared by the renderers: string, unsigned, signed,
//! and JSON string escaping.
//!
//! Note:
//! - Every appender writes at `pos` and returns the new `pos`. The caller owns
//!   the bounds check, so the renderers size their buffer once instead of
//!   re-checking on every field.

const std = @import("std");

// --------------------------------------------------------- //

/// Longest decimal an i64 or u64 can print, sign included.
pub const INT_MAX_DIGITS: usize = 24;

/// Bytes one escaped character can expand to (`\u00xx`). Sizes the worst case
/// a caller must reserve for a string field.
pub const ESCAPE_MAX_EXPANSION: usize = 6;

// --------------------------------------------------------- //

pub fn appendStr(out: []u8, pos: usize, text: []const u8) usize {
    @memcpy(out[pos..][0..text.len], text);

    return pos + text.len;
}

pub fn appendUint(out: []u8, pos: usize, value: u64) usize {
    var tmp: [INT_MAX_DIGITS]u8 = undefined;
    const rendered = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch unreachable;

    return appendStr(out, pos, rendered);
}

pub fn appendInt(out: []u8, pos: usize, value: i64) usize {
    var tmp: [INT_MAX_DIGITS]u8 = undefined;
    const rendered = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch unreachable;

    return appendStr(out, pos, rendered);
}

/// Append `text` as the inside of a JSON string, escaped. The surrounding
/// quotes are the caller's.
///
/// Note:
/// - Worst case is ESCAPE_MAX_EXPANSION bytes per input byte, which is what a
///   caller reserves before calling.
///
/// Param:
/// out - []u8 (destination)
/// pos - usize (write offset)
/// text - []const u8 (raw string to escape)
///
/// Return:
/// - usize (the offset after the escaped text)
pub fn appendJsonStr(out: []u8, pos: usize, text: []const u8) usize {
    const HEX = "0123456789abcdef";

    var cursor = pos;
    for (text) |byte| {
        switch (byte) {
            '"', '\\' => {
                out[cursor] = '\\';
                out[cursor + 1] = byte;
                cursor += 2;
            },
            0x00...0x1f => {
                out[cursor..][0..4].* = "\\u00".*;
                out[cursor + 4] = HEX[byte >> 4];
                out[cursor + 5] = HEX[byte & 0xf];
                cursor += 6;
            },
            else => {
                out[cursor] = byte;
                cursor += 1;
            },
        }
    }

    return cursor;
}
