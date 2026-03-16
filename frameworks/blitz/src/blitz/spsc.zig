const std = @import("std");

/// Lock-free Single-Producer, Single-Consumer queue for fd handoff.
/// One acceptor (producer) → one reactor (consumer) per queue.
/// Capacity must be a power of two.
pub fn SpscQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        buf: []T,
        capacity: usize,
        mask: usize,
        // Cache-line aligned to avoid false sharing between producer and consumer
        head: std.atomic.Value(u64) align(64) = std.atomic.Value(u64).init(0),
        tail: std.atomic.Value(u64) align(64) = std.atomic.Value(u64).init(0),

        pub fn init(alloc: std.mem.Allocator, capacity: usize) !Self {
            std.debug.assert(capacity > 0 and (capacity & (capacity - 1)) == 0); // power of 2
            const buf = try alloc.alloc(T, capacity);
            return .{
                .buf = buf,
                .capacity = capacity,
                .mask = capacity - 1,
            };
        }

        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            alloc.free(self.buf);
        }

        /// Enqueue a value. Returns true on success, false if full.
        /// Called only by the producer thread.
        pub fn enqueue(self: *Self, val: T) bool {
            const tail = self.tail.load(.monotonic);
            const head = self.head.load(.acquire);
            if (tail -% head >= self.capacity) return false;
            self.buf[tail & self.mask] = val;
            self.tail.store(tail +% 1, .release);
            return true;
        }

        /// Dequeue a value. Returns the value or null if empty.
        /// Called only by the consumer thread.
        pub fn dequeue(self: *Self) ?T {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.acquire);
            if (head >= tail) return null;
            const val = self.buf[head & self.mask];
            self.head.store(head +% 1, .release);
            return val;
        }
    };
}

// ── Tests ───────────────────────────────────────────────────────────

test "SpscQueue basic enqueue/dequeue" {
    var q = try SpscQueue(i32).init(std.testing.allocator, 8);
    defer q.deinit(std.testing.allocator);

    try std.testing.expect(q.enqueue(42));
    try std.testing.expect(q.enqueue(99));

    try std.testing.expectEqual(@as(?i32, 42), q.dequeue());
    try std.testing.expectEqual(@as(?i32, 99), q.dequeue());
    try std.testing.expectEqual(@as(?i32, null), q.dequeue());
}

test "SpscQueue full queue returns false" {
    var q = try SpscQueue(i32).init(std.testing.allocator, 4);
    defer q.deinit(std.testing.allocator);

    try std.testing.expect(q.enqueue(1));
    try std.testing.expect(q.enqueue(2));
    try std.testing.expect(q.enqueue(3));
    try std.testing.expect(q.enqueue(4));
    try std.testing.expect(!q.enqueue(5)); // full

    // After dequeue, can enqueue again
    try std.testing.expectEqual(@as(?i32, 1), q.dequeue());
    try std.testing.expect(q.enqueue(5));
}

test "SpscQueue wraparound" {
    var q = try SpscQueue(i32).init(std.testing.allocator, 4);
    defer q.deinit(std.testing.allocator);

    // Fill and drain multiple times to test wraparound
    for (0..3) |round| {
        for (0..4) |i| {
            try std.testing.expect(q.enqueue(@intCast(round * 4 + i)));
        }
        for (0..4) |i| {
            try std.testing.expectEqual(@as(?i32, @intCast(round * 4 + i)), q.dequeue());
        }
    }
}
