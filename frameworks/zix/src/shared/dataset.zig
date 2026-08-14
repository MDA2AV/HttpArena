//! Dataset loader for the /json endpoint.
//!
//! Loads the fixed 50-item benchmark dataset once at startup and keeps it as
//! TYPED values: integers stay integers, strings stay raw strings.
//!
//! Note:
//! - Nothing is pre-rendered. The json handler serializes every field on every
//!   request, which is the work the json profile is defined to measure. A
//!   startup pre-render would turn the hot path into a memcpy of bytes built
//!   once, so this loader deliberately does not build any.
//! - The read runs through jzon on .GENERATED, the path its own benchmark puts
//!   at 4.47x the std-backed one. Strings borrow the document rather than being
//!   copied, which is safe here because both live in the arena below.

const std = @import("std");
const zix = @import("zix");

const paths = @import("paths.zig");

const jzon = zix.jzon;

// --------------------------------------------------------- //

/// Items the fixture carries. The /json route takes a count in 1..ITEM_COUNT.
pub const ITEM_COUNT: u8 = 50;

/// Upper bound on the fixture file. The shipped dataset.json is about 12 KB.
const FILE_MAX_BYTES: usize = 4 * 1024 * 1024;

// --------------------------------------------------------- //

pub const Rating = struct {
    score: i64,
    count: i64,
};

/// One dataset row, exactly the fixture's schema and key order.
pub const Item = struct {
    id: i64,
    name: []const u8,
    category: []const u8,
    price: i64,
    quantity: i64,
    active: bool,
    tags: []const []const u8,
    rating: Rating,
};

pub const Dataset = struct {
    items: []const Item,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Dataset) void {
        self.arena.deinit();
    }
};

// --------------------------------------------------------- //

/// Longest body one render of ITEM_COUNT items can produce, measured from the
/// loaded values. The json handler reserves this before rendering.
///
/// Note:
/// - Every string is budgeted at its escaped worst case, so a fixture carrying
///   quotes or control bytes still fits.
pub fn bodyMaxBytes(items: []const Item) usize {
    // {"items":[ ... ],"count":NN}
    var total: usize = "{\"items\":[".len + "],\"count\":".len + INT_MAX_DIGITS + 1;

    for (items) |item| {
        total += itemMaxBytes(item) + 1; // the separating comma
    }

    return total;
}

/// Longest decimal an i64 or u64 can print, sign included.
const INT_MAX_DIGITS: usize = 24;

/// Bytes one escaped character can expand to (`\u00xx`).
const ESCAPE_MAX_EXPANSION: usize = 6;

fn itemMaxBytes(item: Item) usize {
    // The literal field names, punctuation, and braces of one object.
    const FIXED: usize = 160;

    var total: usize = FIXED;
    total += item.name.len * ESCAPE_MAX_EXPANSION;
    total += item.category.len * ESCAPE_MAX_EXPANSION;
    total += INT_MAX_DIGITS * 6; // id, price, quantity, score, count, total

    for (item.tags) |tag| {
        total += tag.len * ESCAPE_MAX_EXPANSION + 3; // quotes plus comma
    }

    return total;
}

// --------------------------------------------------------- //

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    var path_z: [std.posix.PATH_MAX]u8 = undefined;
    if (path.len >= path_z.len) return error.NameTooLong;

    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const fd = try std.posix.openatZ(std.posix.AT.FDCWD, @ptrCast(&path_z), .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.posix.system.close(fd);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.ensureTotalCapacity(allocator, 64 * 1024);
    while (buf.items.len < max) {
        try buf.ensureUnusedCapacity(allocator, 32 * 1024);

        const read = try std.posix.read(fd, buf.unusedCapacitySlice());
        if (read == 0) break;

        buf.items.len += read;
    }

    return buf.toOwnedSlice(allocator);
}

/// Read and decode the fixture.
///
/// Return:
/// - Dataset (caller owns it, call deinit)
/// - error.JzonMissingField and friends when the fixture and Item disagree
pub fn load(gpa: std.mem.Allocator) !Dataset {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    const allocator = arena.allocator();
    const raw = try readFileAlloc(allocator, paths.DATASET, FILE_MAX_BYTES);

    // BORROW is safe: `raw` and the parsed value share this arena, so the
    // document outlives everything pointing into it.
    const items = try jzon.deserialize([]const Item, allocator, raw, .{
        .strategy = .GENERATED,
        .strings = .BORROW,
    });
    if (items.len != ITEM_COUNT) return error.BadDataset;

    return .{ .items = items, .arena = arena };
}
