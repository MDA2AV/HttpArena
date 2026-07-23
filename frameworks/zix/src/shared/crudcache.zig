//! In-process cache for crud single-item reads: direct-mapped slots with
//! per-slot spinlocks, X-Cache MISS/HIT, writes invalidate their id.

const std = @import("std");

// --------------------------------------------------------- //

/// Power of two, covers the 1..50000 bench id keyspace so every id owns its
/// slot (no collision eviction inside the TTL).
const SLOT_COUNT = 65536;
/// Rendered single-item JSON cap, a larger body skips the cache. The seed
/// data bounds a rendered item near 210 bytes (name <= 19, category <= 11,
/// tags <= 48).
const BODY_MAX = 256;

/// Absolute item TTL, the crud profile specifies 200 ms. Writes also
/// invalidate their id.
const ITEM_TTL_MS: i64 = 200;

const Slot = struct {
    lock_flag: std.atomic.Value(bool) = .init(false),
    id: i64 = 0,
    expires_ms: i64 = 0,
    len: u16 = 0,
    body: [BODY_MAX]u8 = undefined,
};

var g_slots: [SLOT_COUNT]Slot = @splat(.{});

fn slotFor(id: i64) ?*Slot {
    if (id < 1) return null;

    return &g_slots[@as(usize, @intCast(id)) & (SLOT_COUNT - 1)];
}

fn lock(flag: *std.atomic.Value(bool)) void {
    while (flag.swap(true, .acquire)) std.atomic.spinLoopHint();
}

fn unlock(flag: *std.atomic.Value(bool)) void {
    flag.store(false, .release);
}

fn nowMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC_COARSE, &ts);

    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Copy a fresh cached body for id into out.
///
/// Return:
/// - the body length (out[0..len] is the item JSON)
/// - null on a miss (absent, expired, or a colliding id)
pub fn get(id: i64, out: []u8) ?usize {
    const slot = slotFor(id) orelse return null;

    lock(&slot.lock_flag);
    defer unlock(&slot.lock_flag);

    if (slot.id != id or slot.len == 0) return null;
    if (nowMs() >= slot.expires_ms) return null;

    const len: usize = slot.len;
    if (len > out.len) return null;
    @memcpy(out[0..len], slot.body[0..len]);

    return len;
}

/// Store a rendered body for id, TTL-bounded. An oversized body is skipped.
pub fn put(id: i64, body: []const u8) void {
    if (body.len > BODY_MAX) return;

    const slot = slotFor(id) orelse return;

    lock(&slot.lock_flag);
    defer unlock(&slot.lock_flag);

    slot.id = id;
    slot.expires_ms = nowMs() + ITEM_TTL_MS;
    slot.len = @intCast(body.len);
    @memcpy(slot.body[0..body.len], body);
}

/// Drop the cached body for id (write invalidation).
pub fn remove(id: i64) void {
    const slot = slotFor(id) orelse return;

    lock(&slot.lock_flag);
    defer unlock(&slot.lock_flag);

    if (slot.id == id) {
        slot.len = 0;
        slot.expires_ms = 0;
    }
}
