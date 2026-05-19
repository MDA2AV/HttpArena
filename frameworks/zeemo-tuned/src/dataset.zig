//! Dataset loader for the HttpArena `json` profile. Stores items as
//! native structs and lets the response handler serialize them per
//! request via zeemo's generic comptime serializer. No pre-rendered
//! response fragments — the `tuned` rules ban that shortcut.

const std = @import("std");
const linux = std.os.linux;

pub const Rating = struct {
    score: i32,
    count: i32,
};

pub const Item = struct {
    id: i32,
    name: []const u8,
    category: []const u8,
    price: i32,
    quantity: i32,
    active: bool,
    tags: []const []const u8,
    rating: Rating,
    /// Computed per request as `price * quantity * m`. Stored on the value
    /// the handler hands to the serializer so it lands as the last field.
    total: i64 = 0,
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

    const items = try aa.alloc(Item, arr.items.len);
    for (arr.items, 0..) |elem, i| {
        const obj = switch (elem) {
            .object => |o| o,
            else => return error.BadDataset,
        };
        const tags_v = obj.get("tags") orelse return error.BadDataset;
        const tags_arr = switch (tags_v) {
            .array => |a| a,
            else => return error.BadDataset,
        };
        const tags = try aa.alloc([]const u8, tags_arr.items.len);
        for (tags_arr.items, 0..) |t, k| tags[k] = try aa.dupe(u8, t.string);
        const rating_v = obj.get("rating") orelse return error.BadDataset;
        const rating_obj = switch (rating_v) {
            .object => |o| o,
            else => return error.BadDataset,
        };

        items[i] = .{
            .id = @intCast(obj.get("id").?.integer),
            .name = try aa.dupe(u8, obj.get("name").?.string),
            .category = try aa.dupe(u8, obj.get("category").?.string),
            .price = @intCast(obj.get("price").?.integer),
            .quantity = @intCast(obj.get("quantity").?.integer),
            .active = obj.get("active").?.bool,
            .tags = tags,
            .rating = .{
                .score = @intCast(rating_obj.get("score").?.integer),
                .count = @intCast(rating_obj.get("count").?.integer),
            },
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
    while (buf.items.len < max) {
        try buf.ensureUnusedCapacity(aa, 32 * 1024);
        const dst = buf.unusedCapacitySlice();
        const n = try std.posix.read(fd, dst);
        if (n == 0) break;
        buf.items.len += n;
    }
    return try buf.toOwnedSlice(aa);
}
