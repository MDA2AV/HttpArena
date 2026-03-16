const std = @import("std");
const mem = std.mem;
const parser = @import("parser.zig");

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
    // Dynamic read buffer for large request bodies (e.g. uploads)
    // When Content-Length exceeds BUF_SIZE, we promote to a heap buffer.
    dyn_buf: ?[]u8 = null,
    dyn_len: usize = 0,
    dyn_alloc: ?std.mem.Allocator = null,
    // WebSocket mode — after upgrade, bypass HTTP parsing
    ws_mode: bool = false,
    // Body discard mode — count body bytes without buffering
    discard_remaining: usize = 0,
    discard_req: ?parser.HeaderResult = null,

    pub fn init(alloc: std.mem.Allocator) ConnState {
        return .{ .write_list = std.ArrayList(u8).init(alloc) };
    }

    /// Touch — update last activity timestamp.
    pub fn touch(self: *ConnState) void {
        const ts = std.posix.clock_gettime(.MONOTONIC) catch return;
        self.last_active = ts.sec;
    }

    /// Promote from static buffer to dynamic heap buffer of given size.
    /// Copies existing data from the static buffer.
    pub fn promoteToDynamic(self: *ConnState, alloc: std.mem.Allocator, needed: usize) bool {
        const buf = alloc.alloc(u8, needed) catch return false;
        if (self.read_len > 0) {
            @memcpy(buf[0..self.read_len], self.read_buf[0..self.read_len]);
        }
        self.dyn_buf = buf;
        self.dyn_len = self.read_len;
        self.dyn_alloc = alloc;
        return true;
    }

    /// Free the dynamic buffer and revert to static.
    pub fn revertToStatic(self: *ConnState) void {
        if (self.dyn_buf) |buf| {
            if (self.dyn_alloc) |alloc| {
                alloc.free(buf);
            }
        }
        self.dyn_buf = null;
        self.dyn_len = 0;
        self.dyn_alloc = null;
        self.read_len = 0;
    }

    /// Get the active read slice (dynamic if promoted, static otherwise).
    pub fn readSlice(self: *ConnState) []const u8 {
        if (self.dyn_buf) |buf| return buf[0..self.dyn_len];
        return self.read_buf[0..self.read_len];
    }

    /// Get remaining writable portion of active buffer.
    pub fn readBufRemaining(self: *ConnState) ?[]u8 {
        if (self.dyn_buf) |buf| {
            if (self.dyn_len >= buf.len) return null;
            return buf[self.dyn_len..];
        }
        if (self.read_len >= BUF_SIZE) return null;
        return self.read_buf[self.read_len..];
    }

    /// Advance read position after successful read.
    pub fn advanceRead(self: *ConnState, n: usize) void {
        if (self.dyn_buf != null) {
            self.dyn_len += n;
        } else {
            self.read_len += n;
        }
    }

    /// Get active read length.
    pub fn activeReadLen(self: *ConnState) usize {
        if (self.dyn_buf != null) return self.dyn_len;
        return self.read_len;
    }

    pub fn reset(self: *ConnState) void {
        self.revertToStatic();
        self.write_list.clearRetainingCapacity();
        self.write_off = 0;
        self.fd = -1;
        self.last_active = 0;
        self.ws_mode = false;
        self.discard_remaining = 0;
        self.discard_req = null;
    }

    pub fn isDiscarding(self: *const ConnState) bool {
        return self.discard_req != null;
    }

    pub fn enterDiscardMode(self: *ConnState, hdr_result: parser.HeaderResult, body_bytes_already: usize) void {
        const cl = hdr_result.content_length orelse 0;
        self.discard_req = hdr_result;
        self.discard_remaining = if (cl > body_bytes_already) cl - body_bytes_already else 0;
        self.read_len = 0;
    }

    pub fn discardBytes(self: *ConnState, n: usize) void {
        if (n >= self.discard_remaining) {
            self.discard_remaining = 0;
        } else {
            self.discard_remaining -= n;
        }
    }

    pub fn discardComplete(self: *const ConnState) bool {
        return self.discard_req != null and self.discard_remaining == 0;
    }

    pub fn finishDiscard(self: *ConnState) ?parser.HeaderResult {
        const result = self.discard_req;
        self.discard_req = null;
        self.discard_remaining = 0;
        self.read_len = 0;
        return result;
    }

    pub fn deinit(self: *ConnState) void {
        self.revertToStatic();
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
