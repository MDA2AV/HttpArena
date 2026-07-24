//! HttpArena: zix
//!
//! Dataset loader for the /json endpoint.
//!
//! Loads the fixed 50-item benchmark dataset once at startup and pre-renders
//! each item as a JSON object fragment (without the closing brace), so the hot
//! path only appends the per-request total and the closing brace.

const std = @import("std");

pub const ItemCount = 50;

pub const Item = struct {
    /// Pre-rendered JSON object for this item, WITHOUT the closing `}`.
    /// Caller appends `,"total":<n>}` per request.
    prefix: []const u8,
    /// price * quantity, pre-multiplied so per-request work is one *m
    /// followed by an integer-to-decimal print.
    pq: u64,
};

pub const Dataset = struct {
    items: []Item,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Dataset) void {
        self.arena.deinit();
    }
};

pub fn load(gpa: std.mem.Allocator, path: []const u8) !Dataset {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const raw = try readFileAlloc(aa, path, 4 * 1024 * 1024);

    var parsed = try std.json.parseFromSlice(std.json.Value, aa, raw, .{});
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.BadDataset,
    };
    if (arr.items.len != ItemCount) return error.BadDataset;

    const items = try aa.alloc(Item, ItemCount);
    for (arr.items, 0..) |elem, i| {
        const obj = switch (elem) {
            .object => |o| o,
            else => return error.BadDataset,
        };
        const price = jsonInt(obj.get("price") orelse return error.BadDataset);
        const quantity = jsonInt(obj.get("quantity") orelse return error.BadDataset);

        var buf: std.ArrayList(u8) = .empty;
        try renderItemPrefix(&buf, aa, obj);
        items[i] = .{
            .prefix = try buf.toOwnedSlice(aa),
            .pq = @as(u64, @intCast(price)) * @as(u64, @intCast(quantity)),
        };
    }

    return .{ .items = items, .arena = arena };
}

fn readFileAlloc(aa: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    var path_z: [std.posix.PATH_MAX]u8 = undefined;
    if (path.len >= path_z.len) return error.NameTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    const fd = try std.posix.openatZ(std.posix.AT.FDCWD, @ptrCast(&path_z), .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.posix.system.close(fd);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(aa);
    try buf.ensureTotalCapacity(aa, 64 * 1024);
    while (buf.items.len < max) {
        try buf.ensureUnusedCapacity(aa, 32 * 1024);
        const dst = buf.unusedCapacitySlice();
        const n = try std.posix.read(fd, dst);
        if (n == 0) break;
        buf.items.len += n;
    }
    return buf.toOwnedSlice(aa);
}

fn jsonInt(v: std.json.Value) i64 {
    return switch (v) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}

fn renderItemPrefix(buf: *std.ArrayList(u8), aa: std.mem.Allocator, obj: std.json.ObjectMap) !void {
    try buf.append(aa, '{');
    var first = true;
    var it = obj.iterator();
    while (it.next()) |kv| {
        if (!first) try buf.append(aa, ',');
        first = false;
        try writeString(buf, aa, kv.key_ptr.*);
        try buf.append(aa, ':');
        try writeValue(buf, aa, kv.value_ptr.*);
    }
    // Intentionally no closing `}` — caller appends `,"total":N}`.
}

fn writeValue(buf: *std.ArrayList(u8), aa: std.mem.Allocator, v: std.json.Value) !void {
    switch (v) {
        .null => try buf.appendSlice(aa, "null"),
        .bool => |b| try buf.appendSlice(aa, if (b) "true" else "false"),
        .integer => |n| try writeInt(buf, aa, n),
        .float => |f| {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{f}) catch unreachable;
            try buf.appendSlice(aa, s);
        },
        .number_string => |ns| try buf.appendSlice(aa, ns),
        .string => |s| try writeString(buf, aa, s),
        .array => |arr| {
            try buf.append(aa, '[');
            for (arr.items, 0..) |e, i| {
                if (i > 0) try buf.append(aa, ',');
                try writeValue(buf, aa, e);
            }
            try buf.append(aa, ']');
        },
        .object => |o| {
            try buf.append(aa, '{');
            var first = true;
            var it = o.iterator();
            while (it.next()) |kv| {
                if (!first) try buf.append(aa, ',');
                first = false;
                try writeString(buf, aa, kv.key_ptr.*);
                try buf.append(aa, ':');
                try writeValue(buf, aa, kv.value_ptr.*);
            }
            try buf.append(aa, '}');
        },
    }
}

fn writeInt(buf: *std.ArrayList(u8), aa: std.mem.Allocator, n: i64) !void {
    var tmp: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
    try buf.appendSlice(aa, s);
}

fn writeString(buf: *std.ArrayList(u8), aa: std.mem.Allocator, s: []const u8) !void {
    try buf.append(aa, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(aa, "\\\""),
            '\\' => try buf.appendSlice(aa, "\\\\"),
            0x00...0x1f => {
                var esc: [6]u8 = undefined;
                _ = std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{c}) catch unreachable;
                try buf.appendSlice(aa, esc[0..6]);
            },
            else => try buf.append(aa, c),
        }
    }
    try buf.append(aa, '"');
}
