//! io_uring HTTP/1.1 server core. Forks one worker per allowed CPU, each
//! running an independent io_uring loop with multishot accept; per-
//! connection state is allocated dynamically through `std.heap.page_allocator`
//! and indexed by fd. Pipelined responses batch into an inline 4 KiB write
//! buffer; oversize responses (set via `Response.useBigBuf` or detected by
//! path prefix) borrow a 16 KiB slot from a per-worker pool.
//!
//! This module is purely transport + dispatch. Routing and request/response
//! semantics live in `router.zig`, `request.zig`, `response.zig`.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const IoUring = linux.IoUring;

const http = @import("http.zig");
const router_mod = @import("router.zig");
const Router = router_mod.Router;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

pub const Config = struct {
    port: u16 = 8080,
    /// Highest fd we accept. Indexes a `[MAX_FD]?*Slot` lookup table;
    /// Linux assigns lowest-free fds so this stays sparse under steady load.
    max_fd: u32 = 4096,
    /// Sizing for the per-worker pool of 16 KiB response buffers used by
    /// handlers whose path triggers the big-buffer code path (default:
    /// "/json/" prefix).
    big_pool_size: u32 = 128,
    /// Per-worker io_uring submission queue depth.
    ring_entries: u16 = 4096,
    listen_backlog: u32 = 1024,
    /// If non-null, restrict workers to this CPU count (defaults to the
    /// container's CPU affinity mask).
    worker_count: ?u32 = null,
    /// Per-connection HTTP request-line + headers buffer. Sized to fit the
    /// largest pipelined burst the server expects (defaults work for the
    /// HttpArena 16-deep `pipelined` batch with headroom).
    parser_header_buf: u32 = 2048,
    /// Per-connection body buffer. Increase for upload-style endpoints
    /// (e.g. 20 MiB for HttpArena's `upload` profile).
    parser_body_buf: u32 = 512,
    /// Inline write buffer per connection. Pipelined small-response
    /// batches concatenate here. JSON responses (oversize) use big_buf.
    write_inline_bytes: u32 = 4 * 1024,
    /// "Use the big buffer when path starts with this prefix" hook. The
    /// engine entry uses "/json/"; users can change or set to empty to
    /// disable.
    big_buf_path_prefix: []const u8 = "/json/",
};

const BIG_BUF_SIZE = 16 * 1024;
const MAX_FD: usize = 4096;
const BIG_POOL_SIZE: u32 = 128;

const Op = enum(u8) { accept = 1, recv = 2, send = 3, close = 4 };

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
    parser: http.Parser,
    write_inline: []u8,
    big_idx: ?u32 = null,
    send_ptr: [*]const u8 = undefined,
    send_len: u32 = 0,
    send_off: u32 = 0,
    close_after_send: bool = false,
};

/// Per-worker globals. Held in BSS so children inherit zero-init via COW.
var slot_table: [MAX_FD]?*Slot = .{null} ** MAX_FD;
var big_pool: [BIG_POOL_SIZE][BIG_BUF_SIZE]u8 = undefined;
var big_used: [BIG_POOL_SIZE]bool = undefined;
const slot_allocator = std.heap.page_allocator;

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
fn bigSlice(idx: u32) []u8 {
    return &big_pool[idx];
}

fn getSlot(fd: linux.fd_t) ?*Slot {
    const u: usize = @intCast(fd);
    if (u >= MAX_FD) return null;
    return slot_table[u];
}

fn allocSlotFor(server: *const Server, fd: linux.fd_t) ?*Slot {
    const u: usize = @intCast(fd);
    if (u >= MAX_FD) return null;
    const cfg = &server.config;
    const slot = slot_allocator.create(Slot) catch return null;
    const header_buf = slot_allocator.alloc(u8, cfg.parser_header_buf) catch {
        slot_allocator.destroy(slot);
        return null;
    };
    const body_buf = slot_allocator.alloc(u8, cfg.parser_body_buf) catch {
        slot_allocator.free(header_buf);
        slot_allocator.destroy(slot);
        return null;
    };
    const write_buf = slot_allocator.alloc(u8, cfg.write_inline_bytes) catch {
        slot_allocator.free(body_buf);
        slot_allocator.free(header_buf);
        slot_allocator.destroy(slot);
        return null;
    };
    slot.* = .{
        .fd = fd,
        .parser = .{ .buf = header_buf, .body = body_buf },
        .write_inline = write_buf,
    };
    slot_table[u] = slot;
    return slot;
}

fn freeSlotFor(fd: linux.fd_t) void {
    const u: usize = @intCast(fd);
    if (u >= MAX_FD) return;
    if (slot_table[u]) |slot| {
        if (slot.big_idx) |b| bigRelease(b);
        slot_allocator.free(slot.parser.buf);
        slot_allocator.free(slot.parser.body);
        slot_allocator.free(slot.write_inline);
        slot_allocator.destroy(slot);
        slot_table[u] = null;
    }
}

pub const Server = struct {
    allocator: std.mem.Allocator,
    config: Config,
    router: Router,
    /// Threshold above which inline batching flushes before the next
    /// pipelined response. Leaves room for one more small response.
    inline_flush_at: u32,

    pub fn init(allocator: std.mem.Allocator, config: Config) Server {
        return .{
            .allocator = allocator,
            .config = config,
            .router = Router.init(allocator),
            .inline_flush_at = if (config.write_inline_bytes > 256)
                config.write_inline_bytes - 256
            else
                config.write_inline_bytes / 2,
        };
    }

    pub fn deinit(self: *Server) void {
        self.router.deinit();
    }

    pub fn get(self: *Server, pattern: []const u8, handler: router_mod.HandlerFn) !void {
        try self.router.get(pattern, handler);
    }

    pub fn post(self: *Server, pattern: []const u8, handler: router_mod.HandlerFn) !void {
        try self.router.post(pattern, handler);
    }

    pub fn staticMount(self: *Server, url_prefix: []const u8, fs_root: []const u8, handler: router_mod.HandlerFn) !void {
        try self.router.staticMount(url_prefix, fs_root, handler);
    }

    /// Fork one worker per allowed CPU, run io_uring loops. Never returns
    /// under normal operation.
    pub fn run(self: *Server) !void {
        if (builtin.os.tag != .linux) @panic("zeemo only runs on Linux");

        var sa: linux.Sigaction = .{
            .handler = .{ .handler = linux.SIG.IGN },
            .mask = std.mem.zeroes(linux.sigset_t),
            .flags = 0,
        };
        _ = linux.sigaction(linux.SIG.PIPE, &sa, null);

        var cpu_set: linux.cpu_set_t = undefined;
        if (linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &cpu_set) != 0)
            return error.SchedGetAffinityFailed;
        var cpu_list: [256]u32 = undefined;
        const n_workers = if (self.config.worker_count) |n|
            @min(n, collectCpus(&cpu_set, &cpu_list))
        else
            collectCpus(&cpu_set, &cpu_list);
        if (n_workers == 0) return error.NoAllowedCpus;
        std.log.info("zeemo: spawning {d} worker(s)", .{n_workers});

        var i: u32 = 1;
        while (i < n_workers) : (i += 1) {
            const r = linux.fork();
            switch (linux.errno(r)) {
                .SUCCESS => {
                    if (r == 0) {
                        pinToCpu(cpu_list[i]);
                        self.workerMain(i) catch |err| {
                            std.log.err("zeemo worker {d}: {t}", .{ i, err });
                            std.process.exit(1);
                        };
                        std.process.exit(0);
                    }
                },
                else => return error.ForkFailed,
            }
        }
        pinToCpu(cpu_list[0]);
        try self.workerMain(0);
    }

    fn workerMain(self: *const Server, worker_id: u32) !void {
        const listen_fd = try makeListener(self.config.port, self.config.listen_backlog);
        defer _ = linux.close(listen_fd);
        std.log.info("zeemo: worker {d} listening on :{d}", .{ worker_id, self.config.port });

        var ring = try IoUring.init(self.config.ring_entries, 0);
        defer ring.deinit();

        _ = try ring.accept_multishot(ud(.accept, 0), listen_fd, null, null, 0);

        var cqes: [256]linux.io_uring_cqe = undefined;
        while (true) {
            _ = try ring.submit_and_wait(1);
            const n = try ring.copy_cqes(&cqes, 0);
            var k: u32 = 0;
            while (k < n) : (k += 1) {
                self.handleCqe(&ring, listen_fd, &cqes[k]) catch |err| {
                    std.log.warn("zeemo cqe: {t}", .{err});
                };
            }
        }
    }

    fn handleCqe(self: *const Server, ring: *IoUring, listen_fd: linux.fd_t, cqe: *linux.io_uring_cqe) !void {
        switch (udOp(cqe.user_data)) {
            .accept => try self.handleAccept(ring, listen_fd, cqe),
            .recv => try self.handleRecv(ring, cqe),
            .send => try self.handleSend(ring, cqe),
            .close => freeSlotFor(udFd(cqe.user_data)),
        }
    }

    fn handleAccept(self: *const Server, ring: *IoUring, listen_fd: linux.fd_t, cqe: *linux.io_uring_cqe) !void {
        const more = (cqe.flags & linux.IORING_CQE_F_MORE) != 0;
        if (cqe.res < 0) {
            if (!more) _ = try ring.accept_multishot(ud(.accept, 0), listen_fd, null, null, 0);
            return;
        }
        const fd: linux.fd_t = @intCast(cqe.res);
        const slot = allocSlotFor(self, fd) orelse {
            _ = linux.close(fd);
            if (!more) _ = try ring.accept_multishot(ud(.accept, 0), listen_fd, null, null, 0);
            return;
        };
        const buf = slot.parser.recv_slot();
        _ = try ring.recv(ud(.recv, fd), fd, .{ .buffer = buf }, 0);
        if (!more) _ = try ring.accept_multishot(ud(.accept, 0), listen_fd, null, null, 0);
    }

    fn handleRecv(self: *const Server, ring: *IoUring, cqe: *linux.io_uring_cqe) !void {
        const fd = udFd(cqe.user_data);
        const slot = getSlot(fd) orelse return;
        if (cqe.res <= 0) {
            _ = try ring.close(ud(.close, fd), fd);
            return;
        }
        try self.drainAndSend(ring, slot, @intCast(cqe.res));
    }

    fn handleSend(self: *const Server, ring: *IoUring, cqe: *linux.io_uring_cqe) !void {
        const fd = udFd(cqe.user_data);
        const slot = getSlot(fd) orelse return;
        if (cqe.res <= 0) {
            _ = try ring.close(ud(.close, fd), fd);
            return;
        }
        const n: u32 = @intCast(cqe.res);
        slot.send_off += n;
        if (slot.send_off < slot.send_len) {
            const tail = slot.send_ptr[slot.send_off..slot.send_len];
            _ = try ring.send(ud(.send, fd), fd, tail, linux.MSG.NOSIGNAL);
            return;
        }
        if (slot.close_after_send) {
            _ = try ring.close(ud(.close, fd), fd);
            return;
        }
        try self.drainAndSend(ring, slot, 0);
    }

    fn drainAndSend(self: *const Server, ring: *IoUring, slot: *Slot, initial_n: u32) !void {
        var inline_pos: u32 = 0;
        var feed_n = initial_n;
        while (true) {
            switch (slot.parser.feed(feed_n)) {
                .protocol_error => {
                    if (inline_pos > 0) {
                        submitInline(ring, slot, inline_pos, true) catch {};
                    } else _ = try ring.close(ud(.close, slot.fd), slot.fd);
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
                .ready => |parsed| {
                    feed_n = 0;
                    const needs_big = self.config.big_buf_path_prefix.len > 0 and
                        std.mem.startsWith(u8, parsed.path, self.config.big_buf_path_prefix);
                    if (needs_big) {
                        if (inline_pos > 0) {
                            // Defer big-buf dispatch: flush inline batch first;
                            // parser is left pointing at this request because
                            // we have not yet reset.
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
                        const out_bytes = try dispatchHandler(self, parsed, big);
                        slot.parser.reset(slot.parser.consumed());
                        try submitBig(ring, slot, @intCast(out_bytes.len), parsed.close);
                        return;
                    }
                    const out = slot.write_inline[inline_pos..];
                    const out_bytes = try dispatchHandler(self, parsed, out);
                    if (!ptrInsideSlice(out_bytes.ptr, slot.write_inline)) {
                        // Handler called Response.sendPreBaked — bytes live
                        // outside the inline buffer (mmap'd / arena). Flush
                        // queued inline first (don't reset parser yet; the
                        // pre-baked request re-yields on the next drain
                        // pass), or if inline is empty, ship the external
                        // bytes directly.
                        if (inline_pos > 0) {
                            try submitInline(ring, slot, inline_pos, false);
                            return;
                        }
                        slot.parser.reset(slot.parser.consumed());
                        try submitExternal(ring, slot, out_bytes, parsed.close);
                        return;
                    }
                    inline_pos += @intCast(out_bytes.len);
                    slot.parser.reset(slot.parser.consumed());
                    if (parsed.close) {
                        try submitInline(ring, slot, inline_pos, true);
                        return;
                    }
                    if (inline_pos > self.inline_flush_at) {
                        try submitInline(ring, slot, inline_pos, false);
                        return;
                    }
                },
            }
        }
    }

    /// Run the user handler matching `parsed`, returning the finalized HTTP
    /// response bytes written into `out`. On router miss falls through to a
    /// canned 404.
    fn dispatchHandler(self: *const Server, parsed: http.Request, out: []u8) ![]const u8 {
        const match = self.router.match(parsed.method, parsed.path) orelse {
            return notFound(out, parsed.close);
        };
        const req = Request{
            .method = parsed.method,
            .path = parsed.path,
            .raw_query = parsed.query,
            .body = parsed.body,
            .close = parsed.close,
            .accepts_br = parsed.accepts_br,
            .accepts_gzip = parsed.accepts_gzip,
            .params = match.params,
        };
        var res = Response.init(out, parsed.close);
        match.handler(&req, &res) catch {
            return internalError(out, parsed.close);
        };
        return res.finalize();
    }
};

fn submitInline(ring: *IoUring, slot: *Slot, len: u32, close_after: bool) !void {
    slot.send_ptr = slot.write_inline.ptr;
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

fn submitExternal(ring: *IoUring, slot: *Slot, bytes: []const u8, close_after: bool) !void {
    slot.send_ptr = bytes.ptr;
    slot.send_len = @intCast(bytes.len);
    slot.send_off = 0;
    slot.close_after_send = close_after;
    _ = try ring.send(ud(.send, slot.fd), slot.fd, bytes, linux.MSG.NOSIGNAL);
}

fn ptrInsideSlice(ptr: [*]const u8, slice: []const u8) bool {
    const start = @intFromPtr(slice.ptr);
    const ptr_addr = @intFromPtr(ptr);
    return ptr_addr >= start and ptr_addr < start + slice.len;
}

fn notFound(out: []u8, close: bool) []const u8 {
    var res = Response.init(out, close);
    res.status(404);
    res.text("Not Found") catch return out[0..0];
    return res.finalize();
}

fn internalError(out: []u8, close: bool) []const u8 {
    var res = Response.init(out, close);
    res.status(500);
    res.text("Internal Server Error") catch return out[0..0];
    return res.finalize();
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
    const wi = cpu / @bitSizeOf(usize);
    const bi: u6 = @intCast(cpu % @bitSizeOf(usize));
    set[wi] |= @as(usize, 1) << bi;
    linux.sched_setaffinity(0, &set) catch {};
}

fn makeListener(port: u16, backlog: u32) !linux.fd_t {
    const fd = try syscallResult(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    errdefer _ = linux.close(@intCast(fd));
    const one: c_int = 1;
    const one_bytes = std.mem.asBytes(&one);
    try std.posix.setsockopt(@intCast(fd), linux.SOL.SOCKET, linux.SO.REUSEADDR, one_bytes);
    try std.posix.setsockopt(@intCast(fd), linux.SOL.SOCKET, linux.SO.REUSEPORT, one_bytes);
    try std.posix.setsockopt(@intCast(fd), linux.IPPROTO.TCP, linux.TCP.NODELAY, one_bytes);
    var addr: linux.sockaddr.in = .{
        .family = linux.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = 0,
        .zero = [_]u8{0} ** 8,
    };
    try syscallVoid(linux.bind(@intCast(fd), @ptrCast(&addr), @sizeOf(@TypeOf(addr))));
    try syscallVoid(linux.listen(@intCast(fd), backlog));
    return @intCast(fd);
}

fn syscallResult(r: usize) !usize {
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
    _ = try syscallResult(r);
}
