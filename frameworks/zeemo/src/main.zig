const std = @import("std");
const linux = std.os.linux;
const IoUring = linux.IoUring;
const builtin = @import("builtin");

const http = @import("http.zig");
const handlers = @import("handlers.zig");
const dataset = @import("dataset.zig");

const PORT: u16 = 8080;
/// Highest accepted fd. Reserves an O(1) lookup table; Linux assigns
/// fresh fds starting from the lowest free slot so per-worker fds stay
/// well below this even under churn. 4096 covers HttpArena's entire
/// connection budget per worker with comfortable headroom.
const MAX_FD: usize = 4096;
/// Max concurrent JSON-promoted slots per worker (bounds the big_pool).
const MAX_JSON_CONN = 128;
const RING_ENTRIES = 4096;
const LISTEN_BACKLOG: u32 = 1024;

/// Per-connection inline write buffer. Sized for the small-response
/// profiles (baseline, pipelined, limited-conn) — typical response is
/// ~80 B, so 4 KiB fits a 50-deep pipeline batch with headroom. JSON
/// responses don't fit and use the big-buf pool below.
const WRITE_INLINE = 4 * 1024;
/// When accumulated inline bytes exceed this in a single drain pass we
/// flush before dispatching another request, leaving room for one more
/// pipelined response (~80 B nominally, capped at ~200 B for safety).
const WRITE_INLINE_FLUSH_AT: u32 = WRITE_INLINE - 256;

/// Worker-local big-buffer pool used exclusively for JSON responses.
/// 16 KiB per slot is enough for /json/50?m=N (~10.5 KiB body plus 74 B
/// header). Pool slots are BSS — never touched, never resident — until
/// JSON traffic actually arrives, then released back on connection close.
const BIG_BUF_SIZE = 16 * 1024;
const BIG_POOL_SIZE = MAX_JSON_CONN;

const Op = enum(u8) {
    accept = 1,
    recv = 2,
    send = 3,
    close = 4,
};

/// user_data = (op << 32) | fd. The fd both identifies the operation and
/// is the lookup key into `slot_table`. Linux gives us back the lowest
/// free fd at each accept so the table stays sparse in the low range.
inline fn ud(op: Op, fd: linux.fd_t) u64 {
    return (@as(u64, @intFromEnum(op)) << 32) | @as(u64, @as(u32, @bitCast(fd)));
}
inline fn udOp(u: u64) Op {
    return @enumFromInt(@as(u8, @intCast(u >> 32)));
}
inline fn udFd(u: u64) linux.fd_t {
    return @as(linux.fd_t, @bitCast(@as(u32, @truncate(u))));
}

const Slot = struct {
    fd: linux.fd_t,
    parser: http.Parser = .{},
    /// Inline buffer for small responses (baseline / pipelined /
    /// limited-conn). Pipelined batches concatenate here.
    write_inline: [WRITE_INLINE]u8 = undefined,
    /// Index into `big_pool` if this connection has been promoted to a
    /// large buffer (first /json/ request on the conn). Kept across
    /// requests on the same connection; released to the pool on close.
    big_idx: ?u32 = null,
    /// Pointer + length of whatever buffer the in-flight send is reading
    /// from. Either &write_inline[0] or &big_pool[big_idx][0].
    send_ptr: [*]const u8 = undefined,
    send_len: u32 = 0,
    send_off: u32 = 0,
    close_after_send: bool = false,
};

/// fd-indexed pointer table — null for free fds, *Slot once accepted.
/// 4096 × 8 B = 32 KiB BSS, almost entirely zero-fill (kernel touches
/// only the cache lines holding active fds, ~1 page resident in practice).
var slot_table: [MAX_FD]?*Slot = .{null} ** MAX_FD;

/// Per-worker page-backed allocator. `page_allocator` returns pages via
/// mmap and releases them via munmap on free, so freed Slots actually
/// give memory back to the kernel — important for the limited-conn churn
/// pattern where many connections cycle through.
const slot_allocator = std.heap.page_allocator;

var ds: dataset.Dataset = undefined;

/// Per-worker pool of 16 KiB JSON response buffers. Static BSS — pages
/// stay zero-fill until JSON traffic touches them, so the baseline
/// profile pays zero RSS for this pool.
var big_pool: [BIG_POOL_SIZE][BIG_BUF_SIZE]u8 = undefined;
var big_used: [BIG_POOL_SIZE]bool = undefined;

fn bigAcquire() ?u32 {
    var i: u32 = 0;
    while (i < BIG_POOL_SIZE) : (i += 1) {
        if (!big_used[i]) {
            big_used[i] = true;
            return i;
        }
    }
    return null;
}

fn bigRelease(idx: u32) void {
    big_used[idx] = false;
}

fn getSlot(fd: linux.fd_t) ?*Slot {
    const fdu: usize = @intCast(fd);
    if (fdu >= MAX_FD) return null;
    return slot_table[fdu];
}

fn allocSlotFor(fd: linux.fd_t) ?*Slot {
    const fdu: usize = @intCast(fd);
    if (fdu >= MAX_FD) return null;
    const slot = slot_allocator.create(Slot) catch return null;
    slot.* = .{ .fd = fd };
    slot_table[fdu] = slot;
    return slot;
}

fn freeSlotFor(fd: linux.fd_t) void {
    const fdu: usize = @intCast(fd);
    if (fdu >= MAX_FD) return;
    if (slot_table[fdu]) |slot| {
        if (slot.big_idx) |b| bigRelease(b);
        slot_allocator.destroy(slot);
        slot_table[fdu] = null;
    }
}

pub fn main() !void {
    if (builtin.os.tag != .linux) @panic("zeemo only runs on Linux (io_uring)");

    // Load dataset once in the parent. After fork, every worker inherits
    // the prefix bytes via copy-on-write — they're read-only at runtime so
    // pages stay shared, which keeps memory flat across N workers.
    ds = try dataset.load(std.heap.smp_allocator, "/data/dataset.json");
    std.log.info("loaded {d} dataset items", .{ds.items.len});

    // Ignore SIGPIPE so a peer closing mid-send doesn't kill us; the send()
    // CQE will surface as -EPIPE instead.
    var sa: linux.Sigaction = .{
        .handler = .{ .handler = linux.SIG.IGN },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = 0,
    };
    _ = linux.sigaction(linux.SIG.PIPE, &sa, null);

    // Discover the CPU mask the cgroup actually allows us to use — HttpArena
    // pins the container with `--cpuset-cpus`, so sched_getaffinity gives
    // us the right set (not all online cores). One worker per allowed CPU.
    var cpu_set: linux.cpu_set_t = undefined;
    if (linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &cpu_set) != 0) {
        return error.SchedGetAffinityFailed;
    }
    var cpu_list: [256]u32 = undefined;
    const n_workers = collectCpus(&cpu_set, &cpu_list);
    if (n_workers == 0) return error.NoAllowedCpus;
    std.log.info("spawning {d} worker(s) across cpus", .{n_workers});

    // Fork N-1 children; parent itself becomes worker[0]. Each worker
    // creates its own SO_REUSEPORT listener and runs an independent
    // io_uring loop — fully shared-nothing.
    var i: u32 = 1;
    while (i < n_workers) : (i += 1) {
        const r = linux.fork();
        switch (linux.errno(r)) {
            .SUCCESS => {
                if (r == 0) {
                    pinToCpu(cpu_list[i]);
                    workerMain(i) catch |err| {
                        std.log.err("worker {d}: {t}", .{ i, err });
                        std.process.exit(1);
                    };
                    std.process.exit(0);
                }
                // Parent continues forking.
            },
            else => return error.ForkFailed,
        }
    }
    pinToCpu(cpu_list[0]);
    try workerMain(0);
}

fn collectCpus(set: *const linux.cpu_set_t, list: []u32) u32 {
    var n: u32 = 0;
    for (set, 0..) |word, word_idx| {
        var w = word;
        while (w != 0) : (w &= w - 1) {
            const cpu: u32 = @intCast(word_idx * @bitSizeOf(usize) + @ctz(w));
            if (n >= list.len) return n;
            list[n] = cpu;
            n += 1;
        }
    }
    return n;
}

fn pinToCpu(cpu: u32) void {
    var set: linux.cpu_set_t = std.mem.zeroes(linux.cpu_set_t);
    const word_idx = cpu / @bitSizeOf(usize);
    const bit_idx: u6 = @intCast(cpu % @bitSizeOf(usize));
    set[word_idx] |= @as(usize, 1) << bit_idx;
    linux.sched_setaffinity(0, &set) catch {};
}

fn workerMain(worker_id: u32) !void {
    const listen_fd = try makeListener(PORT);
    defer _ = linux.close(listen_fd);
    std.log.info("worker {d} listening on :{d}", .{ worker_id, PORT });

    var ring = try IoUring.init(RING_ENTRIES, 0);
    defer ring.deinit();

    _ = try ring.accept_multishot(ud(.accept, 0), listen_fd, null, null, 0);

    var cqes: [256]linux.io_uring_cqe = undefined;
    while (true) {
        _ = try ring.submit_and_wait(1);
        const n = try ring.copy_cqes(&cqes, 0);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            handleCqe(&ring, listen_fd, &cqes[i]) catch |err| {
                std.log.warn("cqe handler: {t}", .{err});
            };
        }
    }
}

fn makeListener(port: u16) !linux.fd_t {
    const fd = try syscall(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    errdefer _ = linux.close(@intCast(fd));

    const one: c_int = 1;
    const one_bytes = std.mem.asBytes(&one);
    try std.posix.setsockopt(@intCast(fd), linux.SOL.SOCKET, linux.SO.REUSEADDR, one_bytes);
    try std.posix.setsockopt(@intCast(fd), linux.SOL.SOCKET, linux.SO.REUSEPORT, one_bytes);
    try std.posix.setsockopt(@intCast(fd), linux.IPPROTO.TCP, linux.TCP.NODELAY, one_bytes);

    var addr: linux.sockaddr.in = .{
        .family = linux.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = 0, // INADDR_ANY
        .zero = [_]u8{0} ** 8,
    };
    try syscallVoid(linux.bind(@intCast(fd), @ptrCast(&addr), @sizeOf(@TypeOf(addr))));
    try syscallVoid(linux.listen(@intCast(fd), LISTEN_BACKLOG));
    return @intCast(fd);
}

fn syscall(r: usize) !usize {
    return switch (linux.errno(r)) {
        .SUCCESS => r,
        else => |e| switch (e) {
            .ACCES => error.AccessDenied,
            .ADDRINUSE => error.AddressInUse,
            .ADDRNOTAVAIL => error.AddressNotAvailable,
            .INVAL => error.InvalidArgument,
            .MFILE => error.ProcessFdQuotaExceeded,
            .NFILE => error.SystemFdQuotaExceeded,
            .NOBUFS => error.SystemResources,
            else => error.UnexpectedSyscallError,
        },
    };
}

fn syscallVoid(r: usize) !void {
    _ = try syscall(r);
}

fn handleCqe(ring: *IoUring, listen_fd: linux.fd_t, cqe: *linux.io_uring_cqe) !void {
    switch (udOp(cqe.user_data)) {
        .accept => try handleAccept(ring, listen_fd, cqe),
        .recv => try handleRecv(ring, cqe),
        .send => try handleSend(ring, cqe),
        .close => freeSlotFor(udFd(cqe.user_data)),
    }
}

fn handleAccept(ring: *IoUring, listen_fd: linux.fd_t, cqe: *linux.io_uring_cqe) !void {
    const more = (cqe.flags & linux.IORING_CQE_F_MORE) != 0;
    if (cqe.res < 0) {
        if (!more) _ = try ring.accept_multishot(ud(.accept, 0), listen_fd, null, null, 0);
        return;
    }
    const fd: linux.fd_t = @intCast(cqe.res);
    const slot = allocSlotFor(fd) orelse {
        _ = linux.close(fd);
        if (!more) _ = try ring.accept_multishot(ud(.accept, 0), listen_fd, null, null, 0);
        return;
    };
    const buf = slot.parser.recv_slot();
    _ = try ring.recv(ud(.recv, fd), fd, .{ .buffer = buf }, 0);

    // If multishot fell off, re-arm.
    if (!more) _ = try ring.accept_multishot(ud(.accept, 0), listen_fd, null, null, 0);
}

fn handleRecv(ring: *IoUring, cqe: *linux.io_uring_cqe) !void {
    const fd = udFd(cqe.user_data);
    const slot = getSlot(fd) orelse return; // already freed — race with close CQE
    if (cqe.res <= 0) {
        _ = try ring.close(ud(.close, fd), fd);
        return;
    }
    try drainAndSend(ring, slot, @intCast(cqe.res));
}

fn handleSend(ring: *IoUring, cqe: *linux.io_uring_cqe) !void {
    const fd = udFd(cqe.user_data);
    const slot = getSlot(fd) orelse return;
    if (cqe.res <= 0) {
        _ = try ring.close(ud(.close, fd), fd);
        return;
    }
    const n: u32 = @intCast(cqe.res);
    slot.send_off += n;
    if (slot.send_off < slot.send_len) {
        // Partial send — replay from wherever the active buffer is.
        const tail = slot.send_ptr[slot.send_off..slot.send_len];
        _ = try ring.send(ud(.send, fd), fd, tail, linux.MSG.NOSIGNAL);
        return;
    }
    if (slot.close_after_send) {
        _ = try ring.close(ud(.close, fd), fd);
        return;
    }
    try drainAndSend(ring, slot, 0);
}

/// Drain as many complete requests as fit in the inline write buffer,
/// then submit one send for the whole batch. JSON requests bypass the
/// inline buffer and use the per-connection big_buf instead (pool-backed).
/// If no requests are ready, arm a recv instead.
///
/// `initial_feed_n` is the byte count just delivered by recv (0 when called
/// from handleSend completion).
///
/// HTTP/1.1 pipelining sends N requests back-to-back without waiting for
/// responses, so the first recv often delivers more than one full request.
/// We dispatch all complete requests buffered before submitting one batched
/// send — saves N-1 syscalls and avoids a deadlock that the older
/// "recv → dispatch one → send → recv" code path hit on pipelined input.
fn drainAndSend(ring: *IoUring, slot: *Slot, initial_feed_n: u32) !void {
    var inline_pos: u32 = 0;
    var feed_n = initial_feed_n;

    while (true) {
        const result = slot.parser.feed(feed_n);
        feed_n = 0;
        switch (result) {
            .protocol_error => {
                if (inline_pos > 0) {
                    submitInline(ring, slot, inline_pos, true) catch {};
                } else {
                    _ = try ring.close(ud(.close, slot.fd), slot.fd);
                }
                return;
            },
            .need_more => {
                if (inline_pos > 0) {
                    try submitInline(ring, slot, inline_pos, false);
                    return;
                }
                const buf = slot.parser.recv_slot();
                if (buf.len == 0) {
                    _ = try ring.close(ud(.close, slot.fd), slot.fd);
                    return;
                }
                _ = try ring.recv(ud(.recv, slot.fd), slot.fd, .{ .buffer = buf }, 0);
                return;
            },
            .ready => |req| {
                const needs_big = std.mem.startsWith(u8, req.path, "/json/");
                if (needs_big) {
                    if (inline_pos > 0) {
                        // Flush queued non-JSON bytes first; the JSON
                        // request is re-yielded on the next drain pass
                        // because we haven't called parser.reset yet.
                        try submitInline(ring, slot, inline_pos, false);
                        return;
                    }
                    if (slot.big_idx == null) {
                        slot.big_idx = bigAcquire() orelse {
                            _ = try ring.close(ud(.close, slot.fd), slot.fd);
                            return;
                        };
                    }
                    const big = bigSlice(slot.big_idx.?);
                    const resp = handlers.handle(req, &ds, big);
                    slot.parser.reset(slot.parser.consumed());
                    try submitBig(ring, slot, @intCast(resp.bytes.len), resp.close);
                    return;
                }
                const resp = handlers.handle(req, &ds, slot.write_inline[inline_pos..]);
                inline_pos += @intCast(resp.bytes.len);
                slot.parser.reset(slot.parser.consumed());
                if (resp.close) {
                    try submitInline(ring, slot, inline_pos, true);
                    return;
                }
                if (inline_pos > WRITE_INLINE_FLUSH_AT) {
                    try submitInline(ring, slot, inline_pos, false);
                    return;
                }
                // Loop: feed(0) for the next pipelined request.
            },
        }
    }
}

fn bigSlice(idx: u32) []u8 {
    return &big_pool[idx];
}

fn submitInline(ring: *IoUring, slot: *Slot, len: u32, close_after: bool) !void {
    slot.send_ptr = &slot.write_inline;
    slot.send_len = len;
    slot.send_off = 0;
    slot.close_after_send = close_after;
    _ = try ring.send(ud(.send, slot.fd), slot.fd, slot.write_inline[0..len], linux.MSG.NOSIGNAL);
}

fn submitBig(ring: *IoUring, slot: *Slot, len: u32, close_after: bool) !void {
    const buf = bigSlice(slot.big_idx.?);
    slot.send_ptr = buf.ptr;
    slot.send_len = len;
    slot.send_off = 0;
    slot.close_after_send = close_after;
    _ = try ring.send(ud(.send, slot.fd), slot.fd, buf[0..len], linux.MSG.NOSIGNAL);
}
