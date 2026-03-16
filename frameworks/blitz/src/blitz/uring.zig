const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const mem = std.mem;
const Thread = std.Thread;
const IoUring = linux.IoUring;
const BufferGroup = IoUring.BufferGroup;

const types = @import("types.zig");
const parser = @import("parser.zig");
const Router = @import("router.zig").Router;
const compress_mod = @import("compress.zig");
const log_mod = @import("log.zig");
const SpscQueue = @import("spsc.zig").SpscQueue;
const Request = types.Request;
const Response = types.Response;

// ── Constants ───────────────────────────────────────────────────────
const MAX_CONNS: usize = 65536;
const ACCEPTOR_RING_ENTRIES: u16 = 4096;
const REACTOR_RING_ENTRIES: u16 = 8192;
const CQE_BATCH: usize = 256;
const RECV_BUF_SIZE: u32 = 4096;
const RECV_BUF_COUNT: u16 = 4096; // must be power of 2
const COMPRESS_BUF_SIZE: usize = 131072; // 128KB
const BUFFER_GROUP_ID: u16 = 0;
const SPSC_CAPACITY: usize = 8192; // power of 2

// Socket constants
const SOCK_STREAM: u32 = linux.SOCK.STREAM;
const SOCK_NONBLOCK: u32 = linux.SOCK.NONBLOCK;
const AF_INET: u32 = linux.AF.INET;
const SOL_SOCKET: i32 = 1;
const SO_REUSEPORT: u32 = 15;
const SO_REUSEADDR: u32 = 2;
const IPPROTO_TCP: i32 = 6;
const TCP_NODELAY: u32 = 1;
const MSG_NOSIGNAL: u32 = 0x4000;

// io_uring setup flags
const IORING_SETUP_SINGLE_ISSUER: u32 = 1 << 12; // 5.18+
const IORING_SETUP_DEFER_TASKRUN: u32 = 1 << 13; // 6.1+

// CQE flags
const IORING_CQE_F_MORE: u32 = 1 << 1;
const IORING_CQE_F_NOTIF: u32 = linux.IORING_CQE_F_NOTIF;

// Registered file descriptor flag
const IOSQE_FIXED_FILE: u8 = linux.IOSQE_FIXED_FILE;

// ── User data encoding ─────────────────────────────────────────────
const Op = enum(u8) {
    accept = 1,
    recv = 2,
    send = 3,
    cancel = 4,
    close = 5,
};

fn packUserData(op: Op, fd: i32) u64 {
    return (@as(u64, @intFromEnum(op)) << 56) | @as(u64, @intCast(@as(u32, @bitCast(fd))));
}

fn unpackOp(ud: u64) Op {
    return @enumFromInt(@as(u8, @truncate(ud >> 56)));
}

fn unpackFd(ud: u64) i32 {
    return @bitCast(@as(u32, @truncate(ud)));
}

// ── Connection state ────────────────────────────────────────────────
const ConnState = struct {
    read_buf: [65536]u8 = undefined,
    read_len: usize = 0,
    write_buf: std.ArrayList(u8),
    write_off: usize = 0,
    send_inflight: bool = false,
    zc_notif_pending: bool = false,
    dyn_buf: ?[]u8 = null,
    dyn_len: usize = 0,
    dyn_alloc: ?std.mem.Allocator = null,

    fn init(alloc: std.mem.Allocator) ConnState {
        return .{ .write_buf = std.ArrayList(u8).init(alloc) };
    }

    fn promoteToDynamic(self: *ConnState, a: std.mem.Allocator, needed: usize) bool {
        const buf = a.alloc(u8, needed) catch return false;
        if (self.read_len > 0) {
            @memcpy(buf[0..self.read_len], self.read_buf[0..self.read_len]);
        }
        self.dyn_buf = buf;
        self.dyn_len = self.read_len;
        self.dyn_alloc = a;
        return true;
    }

    fn revertToStatic(self: *ConnState) void {
        if (self.dyn_buf) |buf| {
            if (self.dyn_alloc) |a| a.free(buf);
        }
        self.dyn_buf = null;
        self.dyn_len = 0;
        self.dyn_alloc = null;
        self.read_len = 0;
    }

    fn readSlice(self: *ConnState) []const u8 {
        if (self.dyn_buf) |buf| return buf[0..self.dyn_len];
        return self.read_buf[0..self.read_len];
    }

    fn readBufRemaining(self: *ConnState) ?[]u8 {
        if (self.dyn_buf) |buf| {
            if (self.dyn_len >= buf.len) return null;
            return buf[self.dyn_len..];
        }
        if (self.read_len >= 65536) return null;
        return self.read_buf[self.read_len..];
    }

    fn advanceRead(self: *ConnState, n: usize) void {
        if (self.dyn_buf != null) {
            self.dyn_len += n;
        } else {
            self.read_len += n;
        }
    }

    fn activeReadLen(self: *ConnState) usize {
        if (self.dyn_buf != null) return self.dyn_len;
        return self.read_len;
    }

    fn reset(self: *ConnState) void {
        self.revertToStatic();
        self.write_buf.clearRetainingCapacity();
        self.write_off = 0;
        self.send_inflight = false;
        self.zc_notif_pending = false;
    }

    fn deinit(self: *ConnState) void {
        self.revertToStatic();
        self.write_buf.deinit();
    }
};

// ── Connection Pool ─────────────────────────────────────────────────
const URING_POOL_SIZE: usize = 4096;

const UringConnPool = struct {
    slots: []ConnState,
    free_stack: []u16,
    free_count: usize,
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) ?UringConnPool {
        const slots = alloc.alloc(ConnState, URING_POOL_SIZE) catch return null;
        const stack = alloc.alloc(u16, URING_POOL_SIZE) catch {
            alloc.free(slots);
            return null;
        };
        for (0..URING_POOL_SIZE) |i| {
            stack[i] = @intCast(URING_POOL_SIZE - 1 - i);
        }
        for (slots) |*s| {
            s.* = ConnState.init(alloc);
        }
        return .{ .slots = slots, .free_stack = stack, .free_count = URING_POOL_SIZE, .alloc = alloc };
    }

    fn acquire(self: *UringConnPool) ?*ConnState {
        if (self.free_count == 0) return null;
        self.free_count -= 1;
        const idx = self.free_stack[self.free_count];
        const st = &self.slots[idx];
        st.reset();
        return st;
    }

    fn release(self: *UringConnPool, st: *ConnState) void {
        const base = @intFromPtr(self.slots.ptr);
        const ptr = @intFromPtr(st);
        const stride = @sizeOf(ConnState);
        const idx = (ptr - base) / stride;
        if (idx < URING_POOL_SIZE and self.free_count < URING_POOL_SIZE) {
            self.free_stack[self.free_count] = @intCast(idx);
            self.free_count += 1;
        }
    }

    fn isPooled(self: *UringConnPool, st: *ConnState) bool {
        const base = @intFromPtr(self.slots.ptr);
        const ptr = @intFromPtr(st);
        return ptr >= base and ptr < base + @sizeOf(ConnState) * URING_POOL_SIZE;
    }

    fn deinit(self: *UringConnPool) void {
        for (self.slots) |*s| s.deinit();
        self.alloc.free(self.slots);
        self.alloc.free(self.free_stack);
    }
};

// ── Server Configuration ────────────────────────────────────────────
pub const Config = struct {
    port: u16 = 8080,
    threads: ?usize = null, // null = auto-detect CPU count
    compression: bool = true,
    shutdown_timeout: u32 = 30,
    logging: log_mod.LogConfig = .{},
};

// ── Shared shutdown state ───────────────────────────────────────────
var shutdown_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn isShuttingDown() bool {
    return shutdown_flag.load(.acquire);
}

// ── Signal handling (self-pipe trick) ───────────────────────────────
var signal_pipe: [2]i32 = .{ -1, -1 };

fn signalHandler(_: c_int) callconv(.C) void {
    const buf = [_]u8{1};
    _ = posix.write(signal_pipe[1], &buf) catch {};
}

const libc = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("signal.h");
});

fn installSignalHandlers() void {
    const pipe_result = linux.syscall2(.pipe2, @intFromPtr(&signal_pipe), 0o4000 | 0o2000000);
    const pipe_signed: i64 = @bitCast(pipe_result);
    if (pipe_signed < 0) return;

    var act: libc.struct_sigaction = std.mem.zeroes(libc.struct_sigaction);
    act.__sigaction_handler = .{ .sa_handler = signalHandler };
    act.sa_flags = libc.SA_RESTART;
    _ = libc.sigaction(libc.SIGTERM, &act, null);
    _ = libc.sigaction(libc.SIGINT, &act, null);
}

// ── Public Server ───────────────────────────────────────────────────
pub const UringServer = struct {
    router: *Router,
    config: Config,

    pub fn init(router: *Router, config: Config) UringServer {
        return .{ .router = router, .config = config };
    }

    pub fn listen(self: *UringServer) !void {
        installSignalHandlers();

        const alloc = std.heap.c_allocator;
        const n_reactors = self.config.threads orelse @max(Thread.getCpuCount() catch 1, 1);

        // Create a single listen socket
        const listen_fd: i32 = @intCast(posix.socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0) catch return error.SocketError);
        setSockOptInt(listen_fd, SOL_SOCKET, SO_REUSEPORT, 1);
        setSockOptInt(listen_fd, SOL_SOCKET, SO_REUSEADDR, 1);

        const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, self.config.port);
        posix.bind(listen_fd, &address.any, address.getOsSockLen()) catch return error.BindError;
        posix.listen(listen_fd, 4096) catch return error.ListenError;

        // Allocate SPSC queues — one per reactor
        var queues = try alloc.alloc(SpscQueue(i32), n_reactors);
        defer alloc.free(queues);
        for (queues) |*q| {
            q.* = try SpscQueue(i32).init(alloc, SPSC_CAPACITY);
        }
        defer {
            for (queues) |*q| q.deinit(alloc);
        }

        // Spawn reactor threads
        var reactor_threads = std.ArrayList(Thread).init(alloc);
        defer reactor_threads.deinit();

        for (0..n_reactors) |i| {
            const t = try Thread.spawn(.{}, reactorThread, .{
                self.router,
                self.config,
                &queues[i],
            });
            try reactor_threads.append(t);
        }

        // Run acceptor on main thread
        acceptorThread(listen_fd, queues, n_reactors);

        // Wait for reactors to finish
        for (reactor_threads.items) |t| {
            t.join();
        }

        posix.close(listen_fd);
    }
};

// ═══════════════════════════════════════════════════════════════════
// ACCEPTOR THREAD — dedicated accept loop, distributes fds round-robin
// ═══════════════════════════════════════════════════════════════════

fn acceptorThread(
    listen_fd: i32,
    queues: []SpscQueue(i32),
    n_reactors: usize,
) void {
    // Acceptor uses a simple io_uring ring — just multishot accept + signal pipe
    var ring = IoUring.init(ACCEPTOR_RING_ENTRIES, 0) catch return;
    defer ring.deinit();

    // Arm multishot accept
    _ = ring.accept_multishot(
        packUserData(.accept, listen_fd),
        listen_fd,
        null,
        null,
        SOCK_NONBLOCK,
    ) catch return;
    _ = ring.submit() catch return;

    // Monitor signal pipe for shutdown
    if (signal_pipe[0] >= 0) {
        _ = ring.poll_add(
            packUserData(.cancel, signal_pipe[0]),
            signal_pipe[0],
            linux.POLL.IN,
        ) catch {};
        _ = ring.submit() catch {};
    }

    var cqes: [CQE_BATCH]linux.io_uring_cqe = undefined;
    var next_reactor: usize = 0;
    const one: c_int = 1;

    while (!shutdown_flag.load(.acquire)) {
        const count = ring.copy_cqes(&cqes, 1) catch |err| {
            if (err == error.SignalInterrupt) continue;
            break;
        };
        if (count == 0) continue;

        var needs_submit = false;

        for (cqes[0..count]) |cqe| {
            const ud = cqe.user_data;
            if (ud == 0) continue;
            const op = unpackOp(ud);
            const fd = unpackFd(ud);
            const res = cqe.res;

            switch (op) {
                .accept => {
                    if (res >= 0) {
                        const client_fd: i32 = res;

                        // Set TCP_NODELAY on accepted fd (acceptor has the real fd)
                        posix.setsockopt(client_fd, IPPROTO_TCP, TCP_NODELAY, &mem.toBytes(one)) catch {};

                        // Round-robin distribute to reactors
                        const target = next_reactor;
                        next_reactor = (next_reactor + 1) % n_reactors;

                        // Spin-enqueue (queue is large, should rarely spin)
                        while (!queues[target].enqueue(client_fd)) {
                            // Queue full — brief yield and retry
                            std.atomic.spinLoopHint();
                        }
                    }

                    // Re-arm if kernel dropped multishot
                    if (cqe.flags & IORING_CQE_F_MORE == 0) {
                        _ = ring.accept_multishot(
                            packUserData(.accept, listen_fd),
                            listen_fd,
                            null,
                            null,
                            SOCK_NONBLOCK,
                        ) catch {};
                        needs_submit = true;
                    }
                },

                .cancel => {
                    // Signal pipe — shutdown
                    if (fd == signal_pipe[0]) {
                        var sig_buf: [16]u8 = undefined;
                        _ = posix.read(signal_pipe[0], &sig_buf) catch {};
                        shutdown_flag.store(true, .release);
                    }
                },

                else => {},
            }
        }

        if (needs_submit) {
            _ = ring.submit() catch {};
        }
    }
}

// ═══════════════════════════════════════════════════════════════════
// REACTOR THREAD — handles I/O for connections assigned by acceptor
// ═══════════════════════════════════════════════════════════════════

fn reactorThread(
    router: *Router,
    config: Config,
    queue: *SpscQueue(i32),
) void {
    const alloc = std.heap.c_allocator;
    const compression_enabled = config.compression;
    const log_config = config.logging;
    const logging = log_config.enabled;

    // Initialize io_uring with SINGLE_ISSUER + DEFER_TASKRUN
    var params = mem.zeroInit(linux.io_uring_params, .{
        .flags = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN,
        .sq_thread_idle = 1000,
    });

    var ring = IoUring.init_params(REACTOR_RING_ENTRIES, &params) catch blk: {
        var params2 = mem.zeroInit(linux.io_uring_params, .{
            .flags = IORING_SETUP_SINGLE_ISSUER,
            .sq_thread_idle = 1000,
        });
        break :blk IoUring.init_params(REACTOR_RING_ENTRIES, &params2) catch blk2: {
            break :blk2 IoUring.init(REACTOR_RING_ENTRIES, 0) catch return;
        };
    };
    defer ring.deinit();

    // send_zc probe state: 0 = untested, 1 = supported, 2 = unsupported
    var send_zc_state: u8 = 0;

    // Buffer ring for recv
    const slab_size: usize = @as(usize, RECV_BUF_COUNT) * @as(usize, RECV_BUF_SIZE);
    const slab = alloc.alloc(u8, slab_size) catch return;
    defer alloc.free(slab);

    var buf_group = BufferGroup.init(&ring, BUFFER_GROUP_ID, slab, RECV_BUF_SIZE, RECV_BUF_COUNT) catch return;
    defer buf_group.deinit();

    // Connection state (sparse, indexed by fd)
    var conns: [MAX_CONNS]?*ConnState = undefined;
    @memset(&conns, null);

    // Connection pool
    var pool_opt = UringConnPool.init(alloc);
    defer {
        if (pool_opt) |*p| p.deinit();
    }

    // Main reactor event loop
    var cqes: [CQE_BATCH]linux.io_uring_cqe = undefined;

    while (!shutdown_flag.load(.acquire)) {
        // 1. Drain new connections from SPSC queue
        var drained: usize = 0;
        while (queue.dequeue()) |new_fd| {
            const fd_idx: usize = @intCast(@as(u32, @bitCast(new_fd)));
            if (fd_idx >= MAX_CONNS) {
                posix.close(@intCast(@as(u32, @bitCast(new_fd))));
                continue;
            }

            // Acquire ConnState from pool or heap
            const from_pool = if (pool_opt) |*p| p.acquire() else null;
            const st: *ConnState = from_pool orelse alloc.create(ConnState) catch {
                posix.close(@intCast(@as(u32, @bitCast(new_fd))));
                continue;
            };
            if (from_pool == null) {
                st.* = ConnState.init(alloc);
            }
            conns[fd_idx] = st;

            // Arm multishot recv
            _ = buf_group.recv_multishot(
                packUserData(.recv, new_fd),
                new_fd,
                0,
            ) catch {
                releaseConn(&pool_opt, st, alloc);
                conns[fd_idx] = null;
                posix.close(@intCast(@as(u32, @bitCast(new_fd))));
                continue;
            };
            drained += 1;
        }
        if (drained > 0) {
            _ = ring.submit() catch {};
        }

        // 2. Process CQEs
        const count = ring.copy_cqes(&cqes, 1) catch |err| {
            if (err == error.SignalInterrupt) continue;
            break;
        };
        if (count == 0) continue;

        var compress_buf: [COMPRESS_BUF_SIZE]u8 = undefined;
        var needs_submit = false;

        for (cqes[0..count]) |cqe| {
            const ud = cqe.user_data;
            if (ud == 0) continue;
            const op = unpackOp(ud);
            const fd = unpackFd(ud);
            const res = cqe.res;

            switch (op) {
                .recv => {
                    const has_more = (cqe.flags & IORING_CQE_F_MORE) != 0;

                    if (res <= 0) {
                        if (cqe.buffer_id()) |_| {
                            buf_group.put_cqe(cqe) catch {};
                        } else |_| {}
                        closeConn(&conns, &pool_opt, &ring, fd, alloc, false);
                        continue;
                    }

                    const recv_data = buf_group.get_cqe(cqe) catch continue;

                    const uidx: usize = @intCast(@as(u32, @bitCast(fd)));
                    if (uidx < MAX_CONNS) {
                        if (conns[uidx]) |st| {
                            // Copy recv data into connection buffer
                            if (st.dyn_buf) |dbuf| {
                                const space = dbuf.len - st.dyn_len;
                                const copy_len = @min(recv_data.len, space);
                                @memcpy(dbuf[st.dyn_len..][0..copy_len], recv_data[0..copy_len]);
                                st.dyn_len += copy_len;
                            } else {
                                const space = st.read_buf.len - st.read_len;
                                const copy_len = @min(recv_data.len, space);
                                @memcpy(st.read_buf[st.read_len..][0..copy_len], recv_data[0..copy_len]);
                                st.read_len += copy_len;
                            }

                            // Return buffer to kernel (zero-SQE)
                            buf_group.put_cqe(cqe) catch {};

                            // Parse and handle pipelined requests
                            var off: usize = 0;
                            const cur_len = st.activeReadLen();
                            const cur_data = st.readSlice();
                            while (off < cur_len) {
                                const result = parser.parse(cur_data[off..cur_len]) orelse {
                                    const remaining = cur_data[off..cur_len];
                                    if (mem.indexOf(u8, remaining, "\r\n\r\n")) |hdr_end| {
                                        const cl = detectContentLength(remaining[0 .. hdr_end + 4]);
                                        if (cl != null and cl.? > 65536 and st.dyn_buf == null) {
                                            const total_needed = hdr_end + 4 + cl.?;
                                            _ = st.promoteToDynamic(alloc, total_needed);
                                            break;
                                        }
                                        if (st.dyn_buf != null) break;
                                        const bad_resp = "HTTP/1.1 400 Bad Request\r\nContent-Length: 11\r\nConnection: close\r\n\r\nBad Request";
                                        st.write_buf.appendSlice(bad_resp) catch {};
                                        off += hdr_end + 4;
                                        break;
                                    }
                                    break;
                                };
                                var req = result.request;
                                var resp = Response{};

                                if (shutdown_flag.load(.acquire)) {
                                    resp.headers.set("Connection", "close");
                                }

                                const req_start = if (logging) log_mod.now() else 0;
                                router.handle(&req, &resp);

                                if (compression_enabled) {
                                    _ = compress_mod.compressResponse(&compress_buf, &req, &resp);
                                }
                                if (logging) {
                                    log_mod.logRequest(log_config, &req, &resp, req_start);
                                }

                                resp.writeTo(&st.write_buf);
                                off += result.total_len;
                            }

                            // Compact read buffer
                            if (off > 0) {
                                if (st.dyn_buf != null) {
                                    const rem = st.dyn_len - off;
                                    if (rem > 0 and rem <= 65536) {
                                        @memcpy(st.read_buf[0..rem], st.dyn_buf.?[off..st.dyn_len]);
                                    }
                                    st.revertToStatic();
                                    st.read_len = if (rem <= 65536) rem else 0;
                                } else {
                                    const rem = st.read_len - off;
                                    if (rem > 0) std.mem.copyForwards(u8, st.read_buf[0..rem], st.read_buf[off..st.read_len]);
                                    st.read_len = rem;
                                }
                            }

                            // Submit send if data ready
                            if (st.write_buf.items.len > st.write_off and !st.send_inflight) {
                                const send_data = st.write_buf.items[st.write_off..];
                                if (send_zc_state != 2) {
                                    armSendZc(&ring, fd, send_data) catch {
                                        armSend(&ring, fd, send_data) catch {};
                                    };
                                } else {
                                    armSend(&ring, fd, send_data) catch {};
                                }
                                st.send_inflight = true;
                                needs_submit = true;
                            }
                        } else {
                            buf_group.put_cqe(cqe) catch {};
                        }
                    } else {
                        buf_group.put_cqe(cqe) catch {};
                    }

                    // Re-arm recv if multishot dropped
                    if (!has_more) {
                        if (uidx < MAX_CONNS and conns[uidx] != null) {
                            _ = buf_group.recv_multishot(
                                packUserData(.recv, fd),
                                fd,
                                0,
                            ) catch continue;
                            needs_submit = true;
                        }
                    }
                },

                .send => {
                    const uidx: usize = @intCast(@as(u32, @bitCast(fd)));
                    if (uidx >= MAX_CONNS) continue;
                    const st = conns[uidx] orelse continue;

                    // send_zc notification — buffer safe to reuse
                    if (cqe.flags & IORING_CQE_F_NOTIF != 0) {
                        st.zc_notif_pending = false;
                        if (!st.send_inflight) {
                            st.write_buf.clearRetainingCapacity();
                            st.write_off = 0;
                            if (shutdown_flag.load(.acquire)) {
                                closeConn(&conns, &pool_opt, &ring, fd, alloc, false);
                            }
                        }
                        continue;
                    }

                    if (res <= 0) {
                        if (send_zc_state == 0 and (res == -22 or res == -38)) {
                            send_zc_state = 2;
                            armSend(&ring, fd, st.write_buf.items[st.write_off..]) catch {
                                st.send_inflight = false;
                            };
                            needs_submit = true;
                            continue;
                        }
                        closeConn(&conns, &pool_opt, &ring, fd, alloc, false);
                        continue;
                    }

                    if (send_zc_state == 0 and (cqe.flags & IORING_CQE_F_MORE) != 0) {
                        send_zc_state = 1;
                    }

                    const zc_notif_coming = (cqe.flags & IORING_CQE_F_MORE) != 0;
                    if (zc_notif_coming) {
                        st.zc_notif_pending = true;
                    }

                    st.write_off += @as(usize, @intCast(res));

                    if (st.write_off < st.write_buf.items.len) {
                        // Partial send — use regular send for remainder
                        armSend(&ring, fd, st.write_buf.items[st.write_off..]) catch {
                            st.send_inflight = false;
                        };
                        needs_submit = true;
                    } else {
                        st.send_inflight = false;
                        if (!st.zc_notif_pending) {
                            st.write_buf.clearRetainingCapacity();
                            st.write_off = 0;
                            if (shutdown_flag.load(.acquire)) {
                                closeConn(&conns, &pool_opt, &ring, fd, alloc, false);
                            }
                        }
                    }
                },

                .close => {},
                .cancel => {},
                .accept => {}, // reactor doesn't accept — this shouldn't happen
            }
        }

        if (needs_submit) {
            _ = ring.submit() catch {};
        }
    }

    // Cleanup all connections
    for (0..MAX_CONNS) |i| {
        if (conns[i]) |st| {
            releaseConn(&pool_opt, st, alloc);
            conns[i] = null;
            posix.close(@intCast(i));
        }
    }
}

// ── Helpers ─────────────────────────────────────────────────────────

fn releaseConn(pool_opt: *?UringConnPool, st: *ConnState, alloc: std.mem.Allocator) void {
    if (pool_opt.*) |*p| {
        if (p.isPooled(st)) {
            p.release(st);
            return;
        }
    }
    st.deinit();
    alloc.destroy(st);
}

fn closeConn(
    conns: *[MAX_CONNS]?*ConnState,
    pool_opt: *?UringConnPool,
    ring: *IoUring,
    fd: i32,
    alloc: std.mem.Allocator,
    use_direct_fds: bool,
) void {
    const uidx: usize = @intCast(@as(u32, @bitCast(fd)));
    if (uidx < MAX_CONNS) {
        if (conns[uidx]) |st| {
            releaseConn(pool_opt, st, alloc);
            conns[uidx] = null;
        }
    }
    if (use_direct_fds) {
        _ = ring.close_direct(packUserData(.close, fd), @intCast(@as(u32, @bitCast(fd)))) catch {};
    } else {
        posix.close(@intCast(@as(u32, @bitCast(fd))));
    }
}

fn armSend(ring: *IoUring, fd: i32, data: []const u8) !void {
    _ = try ring.send(packUserData(.send, fd), fd, data, MSG_NOSIGNAL);
}

fn armSendZc(ring: *IoUring, fd: i32, data: []const u8) !void {
    _ = try ring.send_zc(packUserData(.send, fd), fd, data, MSG_NOSIGNAL, 0);
}

fn setSockOptInt(fd: i32, level: i32, optname: u32, val: c_int) void {
    const v = mem.toBytes(val);
    posix.setsockopt(fd, level, optname, &v) catch {};
}

/// Scan raw header bytes for a Content-Length value.
pub fn detectContentLength(headers: []const u8) ?usize {
    var pos: usize = 0;
    while (pos < headers.len) {
        const line_end = mem.indexOf(u8, headers[pos..], "\r\n") orelse headers.len - pos;
        const line = headers[pos .. pos + line_end];
        if (line.len > 16) {
            const colon = mem.indexOfScalar(u8, line, ':') orelse {
                pos += line_end + 2;
                continue;
            };
            const name = line[0..colon];
            if (name.len == 14 and types.asciiEqlIgnoreCase(name, "Content-Length")) {
                const value = mem.trimLeft(u8, line[colon + 1 ..], " ");
                return std.fmt.parseInt(usize, value, 10) catch null;
            }
        }
        pos += line_end + 2;
    }
    return null;
}
