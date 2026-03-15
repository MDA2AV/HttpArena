const std = @import("std");
const mem = std.mem;

// ── Connection Pool ─────────────────────────────────────────────────
// Pre-allocates ConnState objects to avoid malloc/free per connection.
// Uses a lock-free stack (single-threaded per epoll worker) for O(1) acquire/release.
//
// Each worker thread gets its own pool — no cross-thread contention.

const BUF_SIZE: usize = 65536;

pub const ConnState = struct {
    read_buf: [BUF_SIZE]u8 = undefined,
    read_len: usize = 0,
    write_list: std.ArrayList(u8),
    write_off: usize = 0,
    // Pool linkage — index of next free slot (or null sentinel)
    pool_index: u32 = 0,
    // File descriptor — stored for keep-alive timeout sweeps
    fd: i32 = -1,
    // Keep-alive: timestamp of last activity (monotonic clock, seconds)
    last_active: i64 = 0,

    pub fn init(alloc: std.mem.Allocator) ConnState {
        return .{ .write_list = std.ArrayList(u8).init(alloc) };
    }

    /// Touch — update last activity timestamp.
    pub fn touch(self: *ConnState) void {
        const ts = std.posix.clock_gettime(.MONOTONIC) catch return;
        self.last_active = ts.sec;
    }

    pub fn reset(self: *ConnState) void {
        self.read_len = 0;
        self.write_list.clearRetainingCapacity();
        self.write_off = 0;
        self.fd = -1;
        self.last_active = 0;
    }

    pub fn deinit(self: *ConnState) void {
        self.write_list.deinit();
    }
};

/// A fixed-size pool of ConnState objects.
/// Uses a free-list stack for O(1) acquire/release.
/// When the pool is exhausted, falls back to heap allocation.
pub const ConnPool = struct {
    slots: []ConnState,
    // Free list as a stack of indices
    free_stack: []u32,
    free_top: usize, // number of free slots (stack pointer)
    alloc: std.mem.Allocator,
    capacity: usize,
    // Stats
    pool_hits: usize = 0,
    pool_misses: usize = 0,
    fallback_allocs: usize = 0,

    pub fn init(alloc: std.mem.Allocator, capacity: usize) !ConnPool {
        const slots = try alloc.alloc(ConnState, capacity);
        const free_stack = try alloc.alloc(u32, capacity);

        // Initialize all slots and push onto free stack
        for (0..capacity) |i| {
            slots[i] = ConnState.init(alloc);
            slots[i].pool_index = @intCast(i);
            free_stack[i] = @intCast(i);
        }

        return .{
            .slots = slots,
            .free_stack = free_stack,
            .free_top = capacity,
            .alloc = alloc,
            .capacity = capacity,
        };
    }

    /// Acquire a ConnState from the pool.
    /// Returns a pointer to a pooled slot, or heap-allocates if pool is exhausted.
    pub fn acquire(self: *ConnPool) ?*ConnState {
        if (self.free_top > 0) {
            self.free_top -= 1;
            const idx = self.free_stack[self.free_top];
            const state = &self.slots[idx];
            state.reset();
            self.pool_hits += 1;
            return state;
        }

        // Pool exhausted — fall back to heap allocation
        const state = self.alloc.create(ConnState) catch return null;
        state.* = ConnState.init(self.alloc);
        state.pool_index = std.math.maxInt(u32); // sentinel: not from pool
        self.fallback_allocs += 1;
        return state;
    }

    /// Release a ConnState back to the pool.
    /// If it was a heap-allocated fallback, frees it instead.
    pub fn release(self: *ConnPool, state: *ConnState) void {
        if (state.pool_index == std.math.maxInt(u32)) {
            // Heap-allocated fallback — free it
            state.deinit();
            self.alloc.destroy(state);
            return;
        }

        // Return to pool — reset for reuse, retain write_list capacity
        state.reset();
        if (self.free_top < self.capacity) {
            self.free_stack[self.free_top] = state.pool_index;
            self.free_top += 1;
            self.pool_misses += 0; // just to track releases
        }
    }

    pub fn deinit(self: *ConnPool) void {
        for (self.slots) |*s| {
            s.deinit();
        }
        self.alloc.free(self.slots);
        self.alloc.free(self.free_stack);
    }
};
