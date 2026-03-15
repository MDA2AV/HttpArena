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
const Request = types.Request;
const Response = types.Response;

// ── Constants ───────────────────────────────────────────────────────
const MAX_CONNS: usize = 65536;
const RING_ENTRIES: u16 = 4096;
const CQE_BATCH: usize = 256;
const RECV_BUF_SIZE: u32 = 4096;
const RECV_BUF_COUNT: u16 = 4096; // must be power of 2
const SEND_BUF_SIZE: usize = 16384;
const BUFFER_GROUP_ID: u16 = 0;
const COMPRESS_BUF_SIZE: usize = 131072; // 128KB

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

// io_uring setup flags (may not be in Zig 0.14 std)
const IORING_SETUP_SINGLE_ISSUER: u32 = 1 << 12; // 5.18+
const IORING_SETUP_DEFER_TASKRUN: u32 = 1 << 13; // 6.1+

// CQE flags
const IORING_CQE_F_MORE: u32 = 1 << 1;

// ── User data encoding ─────────────────────────────────────────────
// Pack operation type (upper 8 bits) + fd (lower 24 bits) into u64
const Op = enum(u8) {
    accept = 1,
    recv = 2,
    send = 3,
    cancel = 4,
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
    // Accumulated partial request data (when a single recv buffer doesn't have a complete request)
    read_buf: [65536]u8 = undefined,
    read_len: usize = 0,

    // Write buffer for responses
    write_buf: std.ArrayList(u8),

    // Send state
    write_off: usize = 0,
    send_inflight: bool = false,

    fn init(alloc: std.mem.Allocator) ConnState {
        return .{
            .write_buf = std.ArrayList(u8).init(alloc),
        };
    }

    fn reset(self: *ConnState) void {
        self.read_len = 0;
        self.write_buf.clearRetainingCapacity();
        self.write_off = 0;
        self.send_inflight = false;
    }

    fn deinit(self: *ConnState) void {
        self.write_buf.deinit();
    }
};

// ── Server Configuration ────────────────────────────────────────────
pub const Config = struct {
    port: u16 = 8080,
    threads: ?usize = null,
    compression: bool = true,
    shutdown_timeout: u32 = 30,
    logging: log_mod.LogConfig = .{},
};

// ── Shared shutdown state ───────────────────────────────────────────
var shutdown_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn isShuttingDown() bool {
    return shutdown_flag.load(.acquire);
}

// ── Signal handling (self-pipe trick, same as epoll server) ─────────
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

// ── Server ──────────────────────────────────────────────────────────
pub const UringServer = struct {
    router: *Router,
    config: Config,

    pub fn init(router: *Router, config: Config) UringServer {
        return .{ .router = router, .config = config };
    }

    pub fn listen(self: *UringServer) !void {
        installSignalHandlers();

        const n_threads = self.config.threads orelse @max(Thread.getCpuCount() catch 1, 1);

        var threads = std.ArrayList(Thread).init(std.heap.c_allocator);
        defer threads.deinit();

        for (1..n_threads) |_| {
            const t = try Thread.spawn(.{}, workerThread, .{ self.router, self.config, false });
            try threads.append(t);
        }

        workerThread(self.router, self.config, true);

        for (threads.items) |t| {
            t.join();
        }
    }
};

fn workerThread(router: *Router, config: Config, is_primary: bool) void {
    const alloc = std.heap.c_allocator;
    const compression_enabled = config.compression;
    const log_config = config.logging;
    const logging = log_config.enabled;

    // Create listening socket with SO_REUSEPORT
    const sock: i32 = @intCast(posix.socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0) catch return);
    defer posix.close(sock);

    setSockOptInt(sock, SOL_SOCKET, SO_REUSEPORT, 1);
    setSockOptInt(sock, SOL_SOCKET, SO_REUSEADDR, 1);
    setSockOptInt(sock, IPPROTO_TCP, TCP_NODELAY, 1);

    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, config.port);
    posix.bind(sock, &address.any, address.getOsSockLen()) catch return;
    posix.listen(sock, 4096) catch return;

    // Initialize io_uring with SINGLE_ISSUER + DEFER_TASKRUN
    var params = mem.zeroInit(linux.io_uring_params, .{
        .flags = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN,
        .sq_thread_idle = 1000,
    });

    var ring = IoUring.init_params(RING_ENTRIES, &params) catch blk: {
        // Fallback: try without DEFER_TASKRUN (requires kernel 6.1+)
        var params2 = mem.zeroInit(linux.io_uring_params, .{
            .flags = IORING_SETUP_SINGLE_ISSUER,
            .sq_thread_idle = 1000,
        });
        break :blk IoUring.init_params(RING_ENTRIES, &params2) catch blk2: {
            // Fallback: no special flags
            break :blk2 IoUring.init(RING_ENTRIES, 0) catch return;
        };
    };
    defer ring.deinit();

    // Allocate recv buffer slab for BufferGroup
    const slab_size: usize = @as(usize, RECV_BUF_COUNT) * @as(usize, RECV_BUF_SIZE);
    const slab = alloc.alloc(u8, slab_size) catch return;
    defer alloc.free(slab);

    // Initialize kernel-managed buffer ring (replaces provide_buffers)
    // BufferGroup uses shared memory — buffer return is zero-SQE (just a memory write)
    var buf_group = BufferGroup.init(
        &ring,
        BUFFER_GROUP_ID,
        slab,
        RECV_BUF_SIZE,
        RECV_BUF_COUNT,
    ) catch return;
    defer buf_group.deinit();

    // Connection state array (sparse, indexed by fd)
    var conns: [MAX_CONNS]?*ConnState = undefined;
    @memset(&conns, null);

    // Arm multishot accept
    armMultishotAccept(&ring, sock) catch return;
    _ = ring.submit() catch return;

    // Monitor signal pipe on primary thread
    if (is_primary and signal_pipe[0] >= 0) {
        // Use poll_add for signal pipe
        _ = ring.poll_add(
            packUserData(.cancel, signal_pipe[0]),
            signal_pipe[0],
            linux.POLL.IN,
        ) catch {};
        _ = ring.submit() catch {};
    }

    // Main event loop
    var cqes: [CQE_BATCH]linux.io_uring_cqe = undefined;

    while (!shutdown_flag.load(.acquire)) {
        const count = ring.copy_cqes(&cqes, 1) catch |err| {
            if (err == error.SignalInterrupt) continue;
            break;
        };
        if (count == 0) continue;

        var compress_buf: [COMPRESS_BUF_SIZE]u8 = undefined;
        var needs_submit = false;

        for (cqes[0..count]) |cqe| {
            const ud = cqe.user_data;
            if (ud == 0) continue; // internal completion
            const op = unpackOp(ud);
            const fd = unpackFd(ud);
            const res = cqe.res;

            switch (op) {
                .accept => {
                    if (res >= 0) {
                        const client_fd: i32 = res;
                        setSockOptInt(client_fd, IPPROTO_TCP, TCP_NODELAY, 1);

                        const uidx: usize = @intCast(client_fd);
                        if (uidx < MAX_CONNS) {
                            const st = alloc.create(ConnState) catch {
                                posix.close(@intCast(@as(u32, @bitCast(client_fd))));
                                continue;
                            };
                            st.* = ConnState.init(alloc);
                            conns[uidx] = st;

                            // Arm multishot recv using buffer group
                            _ = buf_group.recv_multishot(
                                packUserData(.recv, client_fd),
                                client_fd,
                                0,
                            ) catch {
                                st.deinit();
                                alloc.destroy(st);
                                conns[uidx] = null;
                                posix.close(@intCast(@as(u32, @bitCast(client_fd))));
                                continue;
                            };
                            needs_submit = true;
                        } else {
                            posix.close(@intCast(@as(u32, @bitCast(client_fd))));
                        }
                    }

                    // Re-arm multishot accept if kernel dropped it
                    if (cqe.flags & IORING_CQE_F_MORE == 0) {
                        armMultishotAccept(&ring, sock) catch {};
                        needs_submit = true;
                    }
                },

                .recv => {
                    const has_more = (cqe.flags & IORING_CQE_F_MORE) != 0;

                    if (res <= 0) {
                        // Connection closed or error — return buffer if present
                        if (cqe.buffer_id()) |_| {
                            buf_group.put_cqe(cqe) catch {};
                        } else |_| {}
                        const uidx: usize = @intCast(@as(u32, @bitCast(fd)));
                        if (uidx < MAX_CONNS) {
                            if (conns[uidx]) |st| {
                                st.deinit();
                                alloc.destroy(st);
                                conns[uidx] = null;
                            }
                            posix.close(@intCast(@as(u32, @bitCast(fd))));
                        }
                        continue;
                    }

                    // Get recv data from buffer group
                    const recv_data = buf_group.get_cqe(cqe) catch continue;

                    const uidx: usize = @intCast(@as(u32, @bitCast(fd)));
                    if (uidx < MAX_CONNS) {
                        if (conns[uidx]) |st| {
                            // Copy recv data into connection's read buffer
                            const space = st.read_buf.len - st.read_len;
                            const copy_len = @min(recv_data.len, space);
                            @memcpy(st.read_buf[st.read_len..][0..copy_len], recv_data[0..copy_len]);
                            st.read_len += copy_len;

                            // Return buffer to kernel ASAP (zero-SQE — just a memory write!)
                            buf_group.put_cqe(cqe) catch {};

                            // Parse and handle pipelined requests
                            var off: usize = 0;
                            while (off < st.read_len) {
                                const result = parser.parse(st.read_buf[off..st.read_len]) orelse break;
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
                                const rem = st.read_len - off;
                                if (rem > 0) std.mem.copyForwards(u8, st.read_buf[0..rem], st.read_buf[off..st.read_len]);
                                st.read_len = rem;
                            }

                            // Submit send if we have data and no send in flight
                            if (st.write_buf.items.len > st.write_off and !st.send_inflight) {
                                armSend(&ring, fd, st.write_buf.items[st.write_off..]) catch {};
                                st.send_inflight = true;
                                needs_submit = true;
                            }
                        } else {
                            // No ConnState — still need to return buffer
                            buf_group.put_cqe(cqe) catch {};
                        }
                    } else {
                        // fd out of range — return buffer
                        buf_group.put_cqe(cqe) catch {};
                    }

                    // Re-arm recv if multishot was dropped
                    if (!has_more) {
                        if (uidx < MAX_CONNS and conns[uidx] != null) {
                            _ = buf_group.recv_multishot(
                                packUserData(.recv, fd),
                                fd,
                                0,
                            ) catch {};
                            needs_submit = true;
                        }
                    }
                },

                .send => {
                    const uidx: usize = @intCast(@as(u32, @bitCast(fd)));
                    if (uidx >= MAX_CONNS) continue;
                    const st = conns[uidx] orelse continue;

                    if (res <= 0) {
                        // Send error — close connection
                        st.deinit();
                        alloc.destroy(st);
                        conns[uidx] = null;
                        posix.close(@intCast(@as(u32, @bitCast(fd))));
                        continue;
                    }

                    st.write_off += @as(usize, @intCast(res));

                    if (st.write_off < st.write_buf.items.len) {
                        // Partial send — resubmit remainder
                        armSend(&ring, fd, st.write_buf.items[st.write_off..]) catch {
                            st.send_inflight = false;
                        };
                        needs_submit = true;
                    } else {
                        // Send complete
                        st.send_inflight = false;
                        st.write_buf.clearRetainingCapacity();
                        st.write_off = 0;

                        if (shutdown_flag.load(.acquire)) {
                            st.deinit();
                            alloc.destroy(st);
                            conns[uidx] = null;
                            posix.close(@intCast(@as(u32, @bitCast(fd))));
                        }
                    }
                },

                .cancel => {
                    // Signal pipe readable or cancel completion — check for shutdown
                    if (is_primary and fd == signal_pipe[0]) {
                        var sig_buf: [16]u8 = undefined;
                        _ = posix.read(signal_pipe[0], &sig_buf) catch {};
                        shutdown_flag.store(true, .release);
                    }
                },
            }
        }

        if (needs_submit) {
            _ = ring.submit() catch {};
        }
    }

    // Cleanup: close all connections
    for (0..MAX_CONNS) |i| {
        if (conns[i]) |st| {
            st.deinit();
            alloc.destroy(st);
            conns[i] = null;
            posix.close(@intCast(i));
        }
    }
}

// ── SQE helpers ─────────────────────────────────────────────────────

fn armMultishotAccept(ring: *IoUring, sock: i32) !void {
    _ = try ring.accept_multishot(
        packUserData(.accept, sock),
        sock,
        null,
        null,
        SOCK_NONBLOCK,
    );
}

fn armSend(ring: *IoUring, fd: i32, data: []const u8) !void {
    _ = try ring.send(
        packUserData(.send, fd),
        fd,
        data,
        MSG_NOSIGNAL,
    );
}

fn setSockOptInt(fd: i32, level: i32, optname: u32, val: c_int) void {
    const v = mem.toBytes(val);
    posix.setsockopt(fd, level, optname, &v) catch {};
}
