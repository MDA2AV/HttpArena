//! Generic JSON serializer driven by Zig's comptime reflection.
//!
//! Walks the value's type at compile time and emits JSON bytes per request —
//! no pre-serialized response caches, no per-(URL, params) memoization, no
//! lookup tables. The HttpArena `tuned` profile bans those shortcuts.
//!
//! Supported types:
//! - integers, floats, bool, null/?T
//! - []const u8 → JSON string (with control-char escaping)
//! - slices and arrays of other types → JSON array
//! - structs → JSON object (field names become keys in declaration order)

const std = @import("std");
const Writer = std.Io.Writer;

pub fn write(w: *Writer, value: anytype) Writer.Error!void {
    const T = @TypeOf(value);
    return writeType(w, T, value);
}

fn writeType(w: *Writer, comptime T: type, value: T) Writer.Error!void {
    const info = @typeInfo(T);
    switch (info) {
        .bool => try w.writeAll(if (value) "true" else "false"),
        .int, .comptime_int => try w.print("{d}", .{value}),
        .float, .comptime_float => try w.print("{d}", .{value}),
        .null => try w.writeAll("null"),
        .optional => {
            if (value) |v| try writeType(w, @TypeOf(v), v) else try w.writeAll("null");
        },
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8)
                try writeString(w, value)
            else
                try writeSlice(w, p.child, value),
            .one => switch (@typeInfo(p.child)) {
                .array => |a| if (a.child == u8)
                    try writeString(w, value)
                else
                    try writeSlice(w, a.child, value),
                else => try writeType(w, p.child, value.*),
            },
            else => @compileError("unsupported pointer for JSON: " ++ @typeName(T)),
        },
        .array => |a| {
            if (a.child == u8) try writeString(w, &value)
            else try writeSlice(w, a.child, &value);
        },
        .@"struct" => |s| {
            try w.writeAll("{");
            inline for (s.fields, 0..) |f, i| {
                if (i > 0) try w.writeAll(",");
                try writeString(w, f.name);
                try w.writeAll(":");
                try writeType(w, f.type, @field(value, f.name));
            }
            try w.writeAll("}");
        },
        .@"enum" => try w.print("\"{s}\"", .{@tagName(value)}),
        else => @compileError("JSON: unsupported type " ++ @typeName(T)),
    }
}

fn writeSlice(w: *Writer, comptime Elem: type, slice: anytype) Writer.Error!void {
    try w.writeAll("[");
    for (slice, 0..) |elem, i| {
        if (i > 0) try w.writeAll(",");
        try writeType(w, Elem, elem);
    }
    try w.writeAll("]");
}

fn writeString(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeAll("\"");
    var start: usize = 0;
    for (s, 0..) |c, i| {
        const esc: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => null,
            else => continue,
        };
        if (i > start) try w.writeAll(s[start..i]);
        if (esc) |e| try w.writeAll(e) else try w.print("\\u{x:0>4}", .{c});
        start = i + 1;
    }
    if (start < s.len) try w.writeAll(s[start..]);
    try w.writeAll("\"");
}

test "primitives" {
    var buf: [256]u8 = undefined;
    var w = Writer.fixed(&buf);
    try write(&w, true);
    try w.writeAll(",");
    try write(&w, @as(i32, 42));
    try w.writeAll(",");
    try write(&w, @as(?u8, null));
    try std.testing.expectEqualStrings("true,42,null", w.buffered());
}

test "string with escapes" {
    var buf: [256]u8 = undefined;
    var w = Writer.fixed(&buf);
    try write(&w, "hello\n\"world\"");
    try std.testing.expectEqualStrings("\"hello\\n\\\"world\\\"\"", w.buffered());
}

test "struct with nested array" {
    var buf: [512]u8 = undefined;
    var w = Writer.fixed(&buf);
    const Item = struct { id: u32, name: []const u8, tags: []const []const u8 };
    try write(&w, Item{ .id = 1, .name = "Alpha", .tags = &.{ "a", "b" } });
    try std.testing.expectEqualStrings(
        "{\"id\":1,\"name\":\"Alpha\",\"tags\":[\"a\",\"b\"]}",
        w.buffered(),
    );
}

test "slice of structs" {
    var buf: [512]u8 = undefined;
    var w = Writer.fixed(&buf);
    const Pair = struct { k: []const u8, v: i64 };
    const arr = [_]Pair{ .{ .k = "a", .v = 1 }, .{ .k = "b", .v = 2 } };
    try write(&w, .{ .pairs = &arr, .count = @as(u32, 2) });
    try std.testing.expectEqualStrings(
        "{\"pairs\":[{\"k\":\"a\",\"v\":1},{\"k\":\"b\",\"v\":2}],\"count\":2}",
        w.buffered(),
    );
}
