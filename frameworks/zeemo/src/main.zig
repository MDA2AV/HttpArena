const std = @import("std");
const linux = std.os.linux;
const IoUring = linux.IoUring;
const builtin = @import("builtin");

const http = @import("http.zig");
const handlers = @import("handlers.zig");
const dataset = @import("dataset.zig");

const PORT: u16 = 8080;
/// Per-worker connection cap. The bench distributes 4096 connections across
/// N workers via SO_REUSEPORT (4-tuple hash), so per-worker mean is ≤ 64
/// with σ ≈ 8. 128 gives a healthy margin and roughly 4× less BSS than the
/// previous 1024 — the memory bonus in HttpArena's composite uses
/// `sqrt(rps)/memMB`, so even when rps stays flat the lower RSS bumps the score.
const MAX_CONN = 128;
const RING_ENTRIES = 4096;
const LISTEN_BACKLOG: u32 = 1024;
const WRITE_BUF_SIZE = 16 * 1024;
/// When `write_buf` accumulates more than this in a single drain pass we
/// flush before dispatching another request, leaving headroom for one
/// max-sized JSON response (~10.5 KiB).
const WRITE_FLUSH_AT: u32 = WRITE_BUF_SIZE - 12 * 1024;

const Op = enum(u8) {
    accept = 1,
    recv = 2,
    send = 3,
    close = 4,
};

/// user_data = (op << 56) | slot_idx
inline fn ud(op: Op, slot: u32) u64 {
    return (@as(u64, @intFromEnum(op)) << 56) | @as(u64, slot);
}
inline fn udOp(u: u64) Op {
    return @enumFromInt(@as(u8, @intCast(u >> 56)));
}
inline fn udSlot(u: u64) u32 {
    return @intCast(u & 0x00FFFFFFFFFFFFFF);
}

const Slot = struct {
    fd: linux.fd_t = -1,
    in_use: bool = false,
    parser: http.Parser = .{},
    write_buf: [WRITE_BUF_SIZE]u8 = undefined,
    write_len: u32 = 0,
    write_off: u32 = 0,
    close_after_send: bool = false,
};

var slots: [MAX_CONN]Slot = undefined;
var ds: dataset.Dataset = undefined;

fn allocSlot() ?u32 {
    var i: u32 = 0;
    while (i < MAX_CONN) : (i += 1) {
        if (!slots[i].in_use) {
            slots[i] = .{};
            slots[i].in_use = true;
            return i;
        }
    }
    return null;
}

fn freeSlot(idx: u32) void {
    slots[idx].in_use = false;
    slots[idx].fd = -1;
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
        .close => freeSlot(udSlot(cqe.user_data)),
    }
}

fn handleAccept(ring: *IoUring, listen_fd: linux.fd_t, cqe: *linux.io_uring_cqe) !void {
    const more = (cqe.flags & linux.IORING_CQE_F_MORE) != 0;
    if (cqe.res < 0) {
        if (!more) _ = try ring.accept_multishot(ud(.accept, 0), listen_fd, null, null, 0);
        return;
    }
    const fd: linux.fd_t = @intCast(cqe.res);
    const slot_idx = allocSlot() orelse {
        _ = linux.close(fd);
        if (!more) _ = try ring.accept_multishot(ud(.accept, 0), listen_fd, null, null, 0);
        return;
    };
    slots[slot_idx].fd = fd;
    const buf = slots[slot_idx].parser.recv_slot();
    _ = try ring.recv(ud(.recv, slot_idx), fd, .{ .buffer = buf }, 0);

    // If multishot fell off, re-arm.
    if (!more) _ = try ring.accept_multishot(ud(.accept, 0), listen_fd, null, null, 0);
}

fn handleRecv(ring: *IoUring, cqe: *linux.io_uring_cqe) !void {
    const slot_idx = udSlot(cqe.user_data);
    const slot = &slots[slot_idx];
    if (cqe.res <= 0) {
        _ = try ring.close(ud(.close, slot_idx), slot.fd);
        return;
    }
    try drainAndSend(ring, slot_idx, @intCast(cqe.res));
}

fn handleSend(ring: *IoUring, cqe: *linux.io_uring_cqe) !void {
    const slot_idx = udSlot(cqe.user_data);
    const slot = &slots[slot_idx];
    if (cqe.res <= 0) {
        _ = try ring.close(ud(.close, slot_idx), slot.fd);
        return;
    }
    const n: u32 = @intCast(cqe.res);
    slot.write_off += n;
    if (slot.write_off < slot.write_len) {
        // Partial send — submit a fresh send for the unsent tail.
        const remaining = slot.write_buf[slot.write_off..slot.write_len];
        _ = try ring.send(ud(.send, slot_idx), slot.fd, remaining, linux.MSG.NOSIGNAL);
        return;
    }
    if (slot.close_after_send) {
        _ = try ring.close(ud(.close, slot_idx), slot.fd);
        return;
    }
    // Keep-alive: drain any further pipelined requests already buffered.
    try drainAndSend(ring, slot_idx, 0);
}

/// Drain as many complete requests as fit in `write_buf`, then submit one
/// send for the whole batch. If no requests are ready, arm a recv instead.
/// `initial_feed_n` is the byte count just delivered by recv (0 when called
/// from handleSend completion).
///
/// HTTP/1.1 pipelining sends N requests back-to-back without waiting for
/// responses, so the first recv often delivers more than one full request.
/// Without this drain loop the previous main.zig would dispatch only the
/// first, submit recv, and block — by then the client is already waiting
/// for responses 2..N and we'd deadlock until the recv timeout. Batching
/// also amortizes one send syscall across the whole burst.
fn drainAndSend(ring: *IoUring, slot_idx: u32, initial_feed_n: u32) !void {
    const slot = &slots[slot_idx];
    var write_pos: u32 = 0;
    var feed_n = initial_feed_n;

    while (true) {
        const result = slot.parser.feed(feed_n);
        feed_n = 0;
        switch (result) {
            .protocol_error => {
                if (write_pos > 0) {
                    try submitSend(ring, slot_idx, write_pos, true);
                } else {
                    _ = try ring.close(ud(.close, slot_idx), slot.fd);
                }
                return;
            },
            .need_more => {
                if (write_pos > 0) {
                    try submitSend(ring, slot_idx, write_pos, false);
                    return;
                }
                const buf = slot.parser.recv_slot();
                if (buf.len == 0) {
                    _ = try ring.close(ud(.close, slot_idx), slot.fd);
                    return;
                }
                _ = try ring.recv(ud(.recv, slot_idx), slot.fd, .{ .buffer = buf }, 0);
                return;
            },
            .ready => |req| {
                const resp = handlers.handle(req, &ds, slot.write_buf[write_pos..]);
                write_pos += @intCast(resp.bytes.len);
                slot.parser.reset(slot.parser.consumed());
                if (resp.close) {
                    try submitSend(ring, slot_idx, write_pos, true);
                    return;
                }
                if (write_pos > WRITE_FLUSH_AT) {
                    try submitSend(ring, slot_idx, write_pos, false);
                    return;
                }
                // Loop: feed(0) to see if the next pipelined request is here.
            },
        }
    }
}

fn submitSend(ring: *IoUring, slot_idx: u32, len: u32, close_after: bool) !void {
    const slot = &slots[slot_idx];
    slot.write_len = len;
    slot.write_off = 0;
    slot.close_after_send = close_after;
    _ = try ring.send(ud(.send, slot_idx), slot.fd, slot.write_buf[0..len], linux.MSG.NOSIGNAL);
}
