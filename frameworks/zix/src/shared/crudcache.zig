//! Row cache for crud single-item reads: direct-mapped slots with per-slot
//! spinlocks, answering the X-Cache MISS and HIT the profile is defined
//! around. Writes invalidate the id they touch.
//!
//! Note:
//! - This is the one cache in the entry, and it exists because the crud
//!   profile IS a cache-aside test: the validator requires MISS on the first
//!   read of an id and HIT on the second, then MISS again after a write. It
//!   holds a decoded database row, never a rendered HTTP response, so the
//!   status line, headers, and framing are still built per request.
//! - The TTL is the profile's own 200 ms. Nothing else in this entry caches
//!   anything.

const std = @import("std");

// --------------------------------------------------------- //

/// Power of two covering the 1..50000 benchmark id keyspace, so every id owns
/// a slot and nothing evicts a live entry inside its TTL.
const SLOT_COUNT: usize = 65536;

/// Largest single-item body a slot holds. The seeded rows render near 210
/// bytes (name up to 19, category up to 11, tags up to 48), a larger body
/// skips the cache rather than growing every slot.
const BODY_MAX: usize = 256;

/// Absolute item TTL. The crud profile specifies 200 ms.
const ITEM_TTL_MS: i64 = 200;

const Slot = struct {
    lock_flag: std.atomic.Value(bool) = .init(false),
    id: i64 = 0,
    expires_ms: i64 = 0,
    len: u16 = 0,
    body: [BODY_MAX]u8 = undefined,
};

var g_slots: [SLOT_COUNT]Slot = @splat(.{});

// --------------------------------------------------------- //

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
    var timestamp: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC_COARSE, &timestamp);

    return @as(i64, timestamp.sec) * 1000 + @divTrunc(@as(i64, timestamp.nsec), 1_000_000);
}

// --------------------------------------------------------- //

/// Copy a still-fresh row for `id` into `out`.
///
/// Param:
/// id - i64 (item id)
/// out - []u8 (destination for the row JSON)
///
/// Return:
/// - usize (the body length, out[0..len] holds the row)
/// - null on a miss: absent, expired, or a colliding id
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

/// Store a rendered row for `id`, TTL-bounded. An oversized body is skipped.
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

/// Drop the cached row for `id`, the write invalidation path.
pub fn remove(id: i64) void {
    const slot = slotFor(id) orelse return;

    lock(&slot.lock_flag);
    defer unlock(&slot.lock_flag);

    if (slot.id == id) {
        slot.len = 0;
        slot.expires_ms = 0;
    }
}
