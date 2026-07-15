//! In-process cache for crud reads. Single-item slots (x-cache MISS/HIT
//! spans workers, invalidated on write) plus rendered list pages
//! (TTL-bounded staleness only, list content is not invalidated on write).
//! Direct-mapped, a lookup verifies the stored key and the TTL. Per-slot
//! spinlock, slots live in BSS.

const std = @import("std");

// --------------------------------------------------------- //

/// Power of two, covers the 1..50000 bench id keyspace so every id owns its
/// slot (no collision eviction inside the TTL).
const SLOT_COUNT = 65536;
/// Rendered single-item JSON cap, a larger body skips the cache. The seed
/// data bounds a rendered item near 210 bytes (name <= 19, category <= 11,
/// tags <= 48).
const BODY_MAX = 256;

/// Power of two, list-page slots (the bench mix runs ~10 distinct pages).
const LIST_SLOT_COUNT = 32;
/// Rendered list JSON cap, a larger body skips the cache.
const LIST_BODY_MAX = 4096;

/// Item TTL is a safety bound only: every write path invalidates its id, so
/// a longer TTL never serves a stale item. Beyond ~5s the write-invalidation
/// rate dominates misses anyway.
const ITEM_TTL_MS: i64 = 5000;
/// List pages are never invalidated on write, this TTL IS the staleness bound.
const LIST_TTL_MS: i64 = 1000;

const Slot = struct {
    lock_flag: std.atomic.Value(bool) = .init(false),
    id: i64 = 0,
    expires_ms: i64 = 0,
    len: u16 = 0,
    body: [BODY_MAX]u8 = undefined,
};

/// One refresh claim per expired page: the claimer misses (and refills),
/// everyone else serves the stale body meanwhile. A claim not filled within
/// this window may be re-claimed.
const LIST_REFRESH_CLAIM_MS: i64 = 250;

/// Key-scanned entry (not direct-mapped): the bench runs ~10 distinct
/// pages, a hash-indexed table would let two pages ping-pong one slot and
/// turn every list request into a database job.
const ListEntry = struct {
    key: u64 = 0,
    expires_ms: i64 = 0,
    refresh_at_ms: i64 = 0,
    len: u16 = 0,
    body: [LIST_BODY_MAX]u8 = undefined,
};

var g_slots: [SLOT_COUNT]Slot = @splat(.{});
var g_list_entries: [LIST_SLOT_COUNT]ListEntry = @splat(.{});
var g_list_lock: std.atomic.Value(bool) = .init(false);

fn slotFor(id: i64) ?*Slot {
    if (id < 1) return null;

    return &g_slots[@as(usize, @intCast(id)) & (SLOT_COUNT - 1)];
}

/// Caller holds g_list_lock.
fn listFind(key: u64) ?*ListEntry {
    for (&g_list_entries) |*entry| {
        if (entry.key == key) return entry;
    }

    return null;
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

/// Cache key of one list page.
pub fn listKey(category: []const u8, page: i64, limit: i64) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(category);
    hasher.update(std.mem.asBytes(&page));
    hasher.update(std.mem.asBytes(&limit));

    return hasher.final();
}

/// Copy a cached list body for key into out, single-flight on expiry: the
/// first caller past the TTL misses (claiming the refill), later callers
/// serve the stale body until the refill lands.
///
/// Return:
/// - the body length (out[0..len] is the list JSON, fresh or stale)
/// - null on a miss (absent, colliding key, or this caller owns the refill)
pub fn listGet(key: u64, out: []u8) ?usize {
    lock(&g_list_lock);
    defer unlock(&g_list_lock);

    const entry = listFind(key) orelse return null;
    if (entry.len == 0) return null;

    const now = nowMs();
    if (now >= entry.expires_ms) {
        if (now >= entry.refresh_at_ms) {
            entry.refresh_at_ms = now + LIST_REFRESH_CLAIM_MS;

            return null;
        }
    }

    const len: usize = entry.len;
    if (len > out.len) return null;
    @memcpy(out[0..len], entry.body[0..len]);

    return len;
}

/// Fresh-only list lookup for the executor-side re-check: never serves
/// stale and never claims, so a claimed refill always reaches the database.
pub fn listGetFresh(key: u64, out: []u8) ?usize {
    lock(&g_list_lock);
    defer unlock(&g_list_lock);

    const entry = listFind(key) orelse return null;
    if (entry.len == 0) return null;
    if (nowMs() >= entry.expires_ms) return null;

    const len: usize = entry.len;
    if (len > out.len) return null;
    @memcpy(out[0..len], entry.body[0..len]);

    return len;
}

/// Store a rendered list body for key, TTL-bounded. Reuses the key's entry,
/// else an empty or expired one. An oversized body (or a full table of
/// fresh entries) is skipped.
pub fn listPut(key: u64, body: []const u8) void {
    if (body.len > LIST_BODY_MAX) return;

    lock(&g_list_lock);
    defer unlock(&g_list_lock);

    const now = nowMs();
    var target: ?*ListEntry = listFind(key);
    if (target == null) {
        for (&g_list_entries) |*entry| {
            if (entry.key == 0 or now >= entry.expires_ms) {
                target = entry;
                break;
            }
        }
    }

    const entry = target orelse return;
    entry.key = key;
    entry.expires_ms = now + LIST_TTL_MS;
    entry.refresh_at_ms = 0;
    entry.len = @intCast(body.len);
    @memcpy(entry.body[0..body.len], body);
}
