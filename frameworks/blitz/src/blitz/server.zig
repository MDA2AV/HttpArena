const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const mem = std.mem;
const Thread = std.Thread;

const types = @import("types.zig");
const parser = @import("parser.zig");
const Router = @import("router.zig").Router;
const pool_mod = @import("pool.zig");
const ConnPool = pool_mod.ConnPool;
const ConnState = pool_mod.ConnState;
const compress_mod = @import("compress.zig");
const log_mod = @import("log.zig");
const Request = types.Request;
const Response = types.Response;
const websocket = @import("websocket.zig");

// ── Constants ───────────────────────────────────────────────────────
const MAX_EVENTS: usize = 512;
const BUF_SIZE: usize = 65536;
const MAX_CONNS: usize = 65536;
const SOCK_STREAM: u32 = linux.SOCK.STREAM;
const SOCK_NONBLOCK: u32 = linux.SOCK.NONBLOCK;
const AF_INET: u32 = linux.AF.INET;
const SOL_SOCKET: i32 = 1;
const SO_REUSEPORT: u32 = 15;
const SO_REUSEADDR: u32 = 2;
const IPPROTO_TCP: i32 = 6;
const TCP_NODELAY: u32 = 1;

// ── Server Configuration ────────────────────────────────────────────
pub const Config = struct {
    port: u16 = 8080,
    threads: ?usize = null, // null = auto-detect
    keep_alive_timeout: u32 = 60, // seconds (0 = disable)
    shutdown_timeout: u32 = 30, // seconds to drain connections before force-close (0 = immediate)
    compression: bool = true, // enable gzip/deflate response compression
    logging: log_mod.LogConfig = .{}, // request logging (disabled by default)
};

// ── Shared shutdown state (atomic, shared across worker threads) ─────
var shutdown_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// ── Shared eventfd for waking non-primary threads on shutdown ────────
var shutdown_eventfd: i32 = -1;

/// Check if the server is shutting down.
pub fn isShuttingDown() bool {
    return shutdown_flag.load(.acquire);
}

// ── Signal pipe (self-pipe trick) ───────────────────────────────────
// Signal handler writes to pipe[1], event loop reads from pipe[0] via epoll.
// Works as PID 1 in Docker — sigaction registers a real handler.
var signal_pipe: [2]i32 = .{ -1, -1 };

fn signalHandler(_: c_int) callconv(.C) void {
    // Write a single byte to wake up the event loop — async-signal-safe
    const buf = [_]u8{1};
    _ = posix.write(signal_pipe[1], &buf) catch {};
}

// C library bindings for signal handling
const libc = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("signal.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
});

/// Install signal handlers for SIGTERM and SIGINT using the self-pipe trick.
fn installSignalHandlers() void {
    // Create a pipe and set non-blocking via raw syscall
    const pipe_result = linux.syscall2(.pipe2, @intFromPtr(&signal_pipe), 0o4000 | 0o2000000);
    const pipe_signed: i64 = @bitCast(pipe_result);
    if (pipe_signed < 0) return;

    // Install signal handlers via libc sigaction
    var act: libc.struct_sigaction = std.mem.zeroes(libc.struct_sigaction);
    act.__sigaction_handler = .{ .sa_handler = signalHandler };
    act.sa_flags = libc.SA_RESTART;

    _ = libc.sigaction(libc.SIGTERM, &act, null);
    _ = libc.sigaction(libc.SIGINT, &act, null);

    // Create eventfd for waking non-primary worker threads
    // EFD_NONBLOCK | EFD_CLOEXEC
    const efd = linux.syscall2(.eventfd2, 0, 0o4000 | 0o2000000);
    const efd_signed: i64 = @bitCast(efd);
    if (efd_signed >= 0) {
        shutdown_eventfd = @intCast(efd_signed);
    }
}

// ── Server ──────────────────────────────────────────────────────────
pub const Server = struct {
    router: *Router,
    config: Config,

    pub fn init(router: *Router, config: Config) Server {
        return .{ .router = router, .config = config };
    }

    /// Start the server — blocks until shutdown signal received
    pub fn listen(self: *Server) !void {
        // Install signal handlers before spawning threads
        installSignalHandlers();

        const n_threads = self.config.threads orelse @max(Thread.getCpuCount() catch 1, 1);

        var threads = std.ArrayList(Thread).init(std.heap.c_allocator);
        defer threads.deinit();

        for (1..n_threads) |_| {
            const t = try Thread.spawn(.{}, workerThread, .{ self.router, self.config, false });
            try threads.append(t);
        }

        // Main thread is the primary worker — it monitors the signal pipe
        workerThread(self.router, self.config, true);

        // Wait for all worker threads to finish
        for (threads.items) |t| {
            t.join();
        }
    }
};

// Default pool size per worker thread
const POOL_SIZE: usize = 4096;

// Per-thread compression buffer size (enough for most responses)
const COMPRESS_BUF_SIZE: usize = 131072; // 128KB

fn workerThread(router: *Router, config: Config, is_primary: bool) void {
    const alloc = std.heap.c_allocator;
    const port = config.port;
    const ka_timeout: i64 = @intCast(config.keep_alive_timeout);
    const drain_timeout: i64 = @intCast(config.shutdown_timeout);
    const compression_enabled = config.compression;
    const log_config = config.logging;

    // Initialize connection pool for this worker
    var pool = ConnPool.init(alloc, POOL_SIZE) catch return;
    _ = &pool;

    const sock: i32 = @intCast(posix.socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0) catch return);
    defer posix.close(sock);

    setSockOptInt(sock, SOL_SOCKET, SO_REUSEPORT, 1);
    setSockOptInt(sock, SOL_SOCKET, SO_REUSEADDR, 1);
    setSockOptInt(sock, IPPROTO_TCP, TCP_NODELAY, 1);

    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
    posix.bind(sock, &address.any, address.getOsSockLen()) catch return;
    posix.listen(sock, 4096) catch return;

    const epfd = posix.epoll_create1(linux.EPOLL.CLOEXEC) catch return;
    defer posix.close(epfd);

    var listen_ev = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .fd = sock } };
    posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, sock, &listen_ev) catch return;

    // Set up timerfd for keep-alive sweep
    var timer_fd: i32 = -1;
    if (ka_timeout > 0) {
        timer_fd = timerfdCreate() orelse -1;
        if (timer_fd >= 0) {
            const half = @divTrunc(ka_timeout, 2);
            const interval: i64 = if (ka_timeout < 20) (if (half > 1) half else 1) else 10;
            timerfdSetInterval(timer_fd, interval);
            var timer_ev = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .fd = timer_fd } };
            posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, timer_fd, &timer_ev) catch {
                posix.close(timer_fd);
                timer_fd = -1;
            };
        }
    }
    defer if (timer_fd >= 0) posix.close(timer_fd);

    // Monitor signal pipe (primary thread) or shutdown eventfd (other threads)
    const sig_fd = signal_pipe[0];
    const evt_fd = shutdown_eventfd;
    if (is_primary and sig_fd >= 0) {
        var sig_ev = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .fd = sig_fd } };
        posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, sig_fd, &sig_ev) catch {};
    } else if (!is_primary and evt_fd >= 0) {
        // Non-primary threads listen on the shared eventfd
        var evt_ev = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .fd = evt_fd } };
        posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, evt_fd, &evt_ev) catch {};
    }

    var conns: [MAX_CONNS]?*ConnState = undefined;
    @memset(&conns, null);
    var events: [MAX_EVENTS]linux.epoll_event = undefined;

    // Shutdown state
    var accepting = true;
    var drain_start: i64 = 0;

    while (true) {
        // Check if shutdown was triggered by another thread
        if (shutdown_flag.load(.acquire)) {
            if (accepting) {
                posix.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, sock, null) catch {};
                accepting = false;
                if (drain_start == 0) {
                    const ts = std.posix.clock_gettime(.MONOTONIC) catch std.posix.timespec{ .sec = 0, .nsec = 0 };
                    drain_start = ts.sec;
                }
            }

            if (drain_timeout == 0 or !hasActiveConns(&conns)) {
                break;
            }
            if (drain_start > 0) {
                const ts = std.posix.clock_gettime(.MONOTONIC) catch std.posix.timespec{ .sec = 0, .nsec = 0 };
                if (ts.sec - drain_start >= drain_timeout) {
                    forceCloseAll(&pool, &conns, epfd);
                    break;
                }
            }
        }

        // Use 1-second timeout on non-primary threads so they notice shutdown.
        // Primary thread uses -1 (infinite) normally, 500ms during drain.
        const timeout_ms: i32 = if (shutdown_flag.load(.acquire)) 500 else if (is_primary) -1 else 1000;
        const n = posix.epoll_wait(epfd, &events, timeout_ms);
        for (events[0..n]) |ev| {
            const fd = ev.data.fd;

            if (fd == sock) {
                acceptLoop(&pool, sock, epfd, &conns, ka_timeout > 0);
                continue;
            }

            // Signal pipe readable — shutdown signal received
            if (fd == sig_fd and is_primary) {
                // Drain the pipe
                var sig_buf: [16]u8 = undefined;
                _ = posix.read(sig_fd, &sig_buf) catch {};

                // Set global shutdown flag
                shutdown_flag.store(true, .release);

                // Stop accepting
                if (accepting) {
                    posix.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, sock, null) catch {};
                    accepting = false;
                    const ts2 = std.posix.clock_gettime(.MONOTONIC) catch std.posix.timespec{ .sec = 0, .nsec = 0 };
                    drain_start = ts2.sec;
                }

                // Wake up non-primary threads via eventfd
                if (evt_fd >= 0) {
                    const val: u64 = 1;
                    _ = posix.write(evt_fd, std.mem.asBytes(&val)) catch {};
                }

                // If no active connections, break immediately
                if (!hasActiveConns(&conns)) {
                    break;
                }
                continue;
            }

            // Eventfd readable — shutdown notification from primary thread
            if (fd == evt_fd and !is_primary) {
                var evtbuf: [8]u8 = undefined;
                _ = posix.read(evt_fd, &evtbuf) catch {};
                // Flag already set by primary, will be checked at top of loop
                continue;
            }

            // Timer event — sweep idle connections
            if (fd == timer_fd) {
                var timer_buf: [8]u8 = undefined;
                _ = posix.read(timer_fd, &timer_buf) catch {};
                sweepIdleConns(&pool, &conns, epfd, ka_timeout);
                continue;
            }

            const uidx: usize = @intCast(fd);
            if (uidx >= MAX_CONNS) continue;
            const st = conns[uidx] orelse continue;

            if (ev.events & linux.EPOLL.IN != 0) {
                var should_close = false;

                // WebSocket mode — echo frames instead of HTTP parsing
                if (st.ws_mode) {
                    // Read data into the static read buffer
                    while (true) {
                        const ws_rem = if (st.read_len >= BUF_SIZE) null else st.read_buf[st.read_len..];
                        const ws_buf_slice = ws_rem orelse break;
                        if (ws_buf_slice.len == 0) break;
                        const ws_n = posix.read(fd, ws_buf_slice) catch |err| {
                            if (err == error.WouldBlock) break;
                            should_close = true;
                            break;
                        };
                        if (ws_n == 0) {
                            should_close = true;
                            break;
                        }
                        st.read_len += ws_n;
                    }

                    // Parse and echo WebSocket frames
                    var ws_off: usize = 0;
                    while (ws_off < st.read_len) {
                        const parse_result = websocket.parseFrame(st.read_buf[ws_off..st.read_len]) orelse break;
                        const frame = parse_result.frame;
                        switch (frame.opcode) {
                            .text, .binary => {
                                // Echo: build unmasked frame and append to write list
                                var ws_frame_buf: [65536 + 14]u8 = undefined;
                                if (websocket.buildFrame(&ws_frame_buf, frame.opcode, frame.payload, frame.fin)) |echo_frame| {
                                    st.write_list.appendSlice(echo_frame) catch {};
                                }
                            },
                            .ping => {
                                // Respond with pong
                                var pong_buf: [131]u8 = undefined; // 125 max payload + 6 header
                                if (websocket.buildFrame(&pong_buf, .pong, frame.payload, true)) |pong_frame| {
                                    st.write_list.appendSlice(pong_frame) catch {};
                                }
                            },
                            .close => {
                                // Send close frame back
                                var close_buf: [131]u8 = undefined;
                                if (websocket.buildCloseFrame(&close_buf, .normal, "")) |close_frame| {
                                    st.write_list.appendSlice(close_frame) catch {};
                                }
                                should_close = true;
                            },
                            else => {},
                        }
                        ws_off += parse_result.consumed;
                    }

                    // Compact the read buffer
                    if (ws_off > 0) {
                        const ws_rem2 = st.read_len - ws_off;
                        if (ws_rem2 > 0) {
                            std.mem.copyForwards(u8, st.read_buf[0..ws_rem2], st.read_buf[ws_off..st.read_len]);
                        }
                        st.read_len = ws_rem2;
                        st.touch();
                    }

                    // Fall through to write flush below
                } else {

                // Labeled drain loop: after dynamic buffer promotion,
                // we must re-read immediately (edge-triggered epoll won't fire again).
                drain: while (true) {
                    // Body discard mode — drain socket without buffering
                    if (st.isDiscarding()) {
                        var discard_buf: [65536]u8 = undefined;
                        while (st.discard_remaining > 0) {
                            const to_read = @min(discard_buf.len, st.discard_remaining);
                            const n_read = posix.read(fd, discard_buf[0..to_read]) catch |err| {
                                if (err == error.WouldBlock) break;
                                should_close = true;
                                break;
                            };
                            if (n_read == 0) {
                                should_close = true;
                                break;
                            }
                            st.discardBytes(n_read);
                        }

                        if (st.discardComplete()) {
                            if (st.finishDiscard()) |hdr_result| {
                                var req = hdr_result.request;
                                var res = Response{};
                                if (shutdown_flag.load(.acquire)) {
                                    res.headers.set("Connection", "close");
                                }
                                const logging = log_config.enabled;
                                const req_start = if (logging) log_mod.now() else 0;
                                router.handle(&req, &res);
                                if (compression_enabled) {
                                    var compress_buf2: [COMPRESS_BUF_SIZE]u8 = undefined;
                                    _ = compress_mod.compressResponse(&compress_buf2, &req, &res);
                                }
                                if (logging) {
                                    log_mod.logRequest(log_config, &req, &res, req_start);
                                }
                                res.writeTo(&st.write_list);
                                st.touch();
                            }
                        }
                        break;
                    }

                    // Read into active buffer (static or dynamic)
                    while (true) {
                        const rem_buf = st.readBufRemaining() orelse break;
                        if (rem_buf.len == 0) break;
                        const n_read = posix.read(fd, rem_buf) catch |err| {
                            if (err == error.WouldBlock) break; // No more data right now — wait for next epoll event
                            should_close = true;
                            break;
                        };
                        if (n_read == 0) {
                            should_close = true;
                            break;
                        }
                        st.advanceRead(n_read);
                        // If still in static buffer and full, stop — check promotion below
                        if (st.dyn_buf == null and st.read_len >= BUF_SIZE) break;
                    }

                    // Parse and handle pipelined requests
                    var compress_buf: [COMPRESS_BUF_SIZE]u8 = undefined;
                    const logging = log_config.enabled;
                    var off: usize = 0;
                    const cur_len = st.activeReadLen();
                    const cur_data = st.readSlice();
                    while (off < cur_len) {
                        const result = parser.parse(cur_data[off..cur_len]) orelse {
                            const remaining = cur_data[off..cur_len];
                            if (mem.indexOf(u8, remaining, "\r\n\r\n")) |hdr_end| {
                                // Try body discard for large bodies
                                const hdr_data = remaining[0 .. hdr_end + 4];
                                if (parser.parseHeaders(hdr_data)) |hdr_result| {
                                    if (hdr_result.content_length != null and hdr_result.content_length.? > BUF_SIZE) {
                                        const body_bytes_in_buf = cur_len - off - (hdr_end + 4);
                                        st.enterDiscardMode(hdr_result, body_bytes_in_buf);
                                        off = cur_len;
                                        continue :drain; // Re-enter drain to discard remaining body bytes
                                    }
                                }
                                // Genuinely bad request — send 400
                                const bad_resp = "HTTP/1.1 400 Bad Request\r\nServer: blitz\r\nContent-Length: 11\r\nConnection: close\r\n\r\nBad Request";
                                st.write_list.appendSlice(bad_resp) catch {};
                                off += hdr_end + 4;
                                should_close = true;
                                break;
                            }
                            break; // Incomplete data — wait for more
                        };
                        var req = result.request;
                        var res = Response{};

                        // During shutdown, signal clients to close
                        if (shutdown_flag.load(.acquire)) {
                            res.headers.set("Connection", "close");
                        }

                        // Capture start time for request logging
                        const req_start = if (logging) log_mod.now() else 0;

                        router.handle(&req, &res);

                        // Apply response compression if enabled
                        if (compression_enabled) {
                            _ = compress_mod.compressResponse(&compress_buf, &req, &res);
                        }

                        // Log completed request
                        if (logging) {
                            log_mod.logRequest(log_config, &req, &res, req_start);
                        }

                        // Check if handler upgraded to WebSocket
                        if (res.ws_upgraded) {
                            // Build the 101 upgrade response directly into the write list
                            if (req.headers.get("Sec-WebSocket-Key")) |ws_key| {
                                var upgrade_buf: [256]u8 = undefined;
                                if (websocket.buildUpgradeResponse(&upgrade_buf, ws_key, null)) |upgrade_resp| {
                                    st.write_list.appendSlice(upgrade_resp) catch {};
                                }
                            }
                            st.ws_mode = true;
                            off += result.total_len;
                            break;
                        }

                        res.writeTo(&st.write_list);

                        off += result.total_len;
                    }

                    if (off > 0 and !st.isDiscarding()) {
                        if (st.dyn_buf != null) {
                            // Done with large body — revert to static buffer
                            const rem = st.dyn_len - off;
                            if (rem > 0 and rem <= BUF_SIZE) {
                                @memcpy(st.read_buf[0..rem], st.dyn_buf.?[off..st.dyn_len]);
                            }
                            st.revertToStatic();
                            st.read_len = if (rem <= BUF_SIZE) rem else 0;
                        } else {
                            const rem = st.read_len - off;
                            if (rem > 0) std.mem.copyForwards(u8, st.read_buf[0..rem], st.read_buf[off..st.read_len]);
                            st.read_len = rem;
                        }
                        st.touch();
                    }

                    break; // Normal exit from drain loop
                }
                } // end else (non-WebSocket HTTP path)

                // Flush writes
                if (st.write_list.items.len > st.write_off) {
                    const written = posix.write(fd, st.write_list.items[st.write_off..]) catch |err| blk: {
                        if (err == error.WouldBlock) {
                            // Send buffer full — register for EPOLLOUT and retry later
                            var mev = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.OUT | linux.EPOLL.ET, .data = .{ .fd = fd } };
                            posix.epoll_ctl(epfd, linux.EPOLL.CTL_MOD, fd, &mev) catch {};
                            break :blk @as(usize, 0);
                        }
                        should_close = true;
                        break :blk @as(usize, 0);
                    };
                    st.write_off += written;
                    if (st.write_off >= st.write_list.items.len) {
                        st.write_list.clearRetainingCapacity();
                        st.write_off = 0;
                        // During shutdown, close after flush
                        if (shutdown_flag.load(.acquire)) {
                            should_close = true;
                        }
                    } else {
                        var mev = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.OUT | linux.EPOLL.ET, .data = .{ .fd = fd } };
                        posix.epoll_ctl(epfd, linux.EPOLL.CTL_MOD, fd, &mev) catch {};
                    }
                }

                if (should_close and st.write_off >= st.write_list.items.len) {
                    closeConn(&pool, &conns, epfd, fd, uidx);
                    continue;
                }
            }

            if (ev.events & linux.EPOLL.OUT != 0) {
                if (conns[uidx]) |s| {
                    if (s.write_list.items.len > s.write_off) {
                        const w = posix.write(fd, s.write_list.items[s.write_off..]) catch {
                            closeConn(&pool, &conns, epfd, fd, uidx);
                            continue;
                        };
                        s.write_off += w;
                    }
                    if (s.write_off >= s.write_list.items.len) {
                        s.write_list.clearRetainingCapacity();
                        s.write_off = 0;
                        // During shutdown, close after flushing
                        if (shutdown_flag.load(.acquire)) {
                            closeConn(&pool, &conns, epfd, fd, uidx);
                            continue;
                        }
                        var mev = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.ET, .data = .{ .fd = fd } };
                        posix.epoll_ctl(epfd, linux.EPOLL.CTL_MOD, fd, &mev) catch {};
                    }
                }
            }

            if (ev.events & (linux.EPOLL.ERR | linux.EPOLL.HUP) != 0) {
                closeConn(&pool, &conns, epfd, fd, uidx);
            }
        }
    }
}

fn acceptLoop(pool: *ConnPool, sock: i32, epfd: i32, conns: *[MAX_CONNS]?*ConnState, track_time: bool) void {
    while (true) {
        var caddr: posix.sockaddr = undefined;
        var clen: posix.socklen_t = @sizeOf(posix.sockaddr);
        const cfd = posix.accept(sock, &caddr, &clen, SOCK_NONBLOCK) catch break;
        const cfd_i: i32 = @intCast(cfd);
        setSockOptInt(cfd_i, IPPROTO_TCP, TCP_NODELAY, 1);

        const uidx: usize = @intCast(cfd);
        if (uidx >= MAX_CONNS) {
            posix.close(cfd);
            continue;
        }

        const st = pool.acquire() orelse {
            posix.close(cfd);
            continue;
        };
        st.fd = cfd_i;
        if (track_time) st.touch();
        conns[uidx] = st;

        var cev = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.ET, .data = .{ .fd = cfd_i } };
        posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, cfd_i, &cev) catch {
            pool.release(st);
            conns[uidx] = null;
            posix.close(cfd);
        };
    }
}

fn closeConn(pool: *ConnPool, conns: *[MAX_CONNS]?*ConnState, epfd: i32, fd: i32, uidx: usize) void {
    posix.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, fd, null) catch {};
    if (conns[uidx]) |s| {
        pool.release(s);
        conns[uidx] = null;
    }
    posix.close(fd);
}

/// Sweep idle connections that exceed the keep-alive timeout.
fn sweepIdleConns(pool: *ConnPool, conns: *[MAX_CONNS]?*ConnState, epfd: i32, timeout: i64) void {
    const ts = std.posix.clock_gettime(.MONOTONIC) catch return;
    const now = ts.sec;
    const cutoff = now - timeout;

    for (0..MAX_CONNS) |i| {
        if (conns[i]) |st| {
            if (st.last_active > 0 and st.last_active < cutoff) {
                const fd: i32 = @intCast(i);
                closeConn(pool, conns, epfd, fd, i);
            }
        }
    }
}

/// Check if there are any active connections.
fn hasActiveConns(conns: *const [MAX_CONNS]?*ConnState) bool {
    for (conns) |conn| {
        if (conn != null) return true;
    }
    return false;
}

/// Force-close all remaining connections (shutdown timeout expired).
fn forceCloseAll(pool: *ConnPool, conns: *[MAX_CONNS]?*ConnState, epfd: i32) void {
    for (0..MAX_CONNS) |i| {
        if (conns[i]) |_| {
            const fd: i32 = @intCast(i);
            closeConn(pool, conns, epfd, fd, i);
        }
    }
}

// ── timerfd helpers ─────────────────────────────────────────────────

const TFD_CLOEXEC = 0o2000000;
const TFD_NONBLOCK = 0o4000;

fn timerfdCreate() ?i32 {
    const fd = linux.syscall2(.timerfd_create, 1, TFD_NONBLOCK | TFD_CLOEXEC);
    const signed: i64 = @bitCast(fd);
    if (signed < 0) return null;
    return @intCast(signed);
}

const Timespec = extern struct {
    sec: i64,
    nsec: i64,
};

const Itimerspec = extern struct {
    interval: Timespec,
    value: Timespec,
};

fn timerfdSetInterval(fd: i32, seconds: i64) void {
    const spec = Itimerspec{
        .interval = .{ .sec = seconds, .nsec = 0 },
        .value = .{ .sec = seconds, .nsec = 0 },
    };
    _ = linux.syscall4(.timerfd_settime, @as(usize, @intCast(fd)), 0, @intFromPtr(&spec), 0);
}

fn setSockOptInt(fd: i32, level: i32, optname: u32, val: c_int) void {
    const v = mem.toBytes(val);
    posix.setsockopt(fd, level, optname, &v) catch {};
}

/// Scan raw header bytes for a Content-Length value.
/// Returns the parsed value or null if not found.
pub fn detectContentLength(headers: []const u8) ?usize {
    var pos: usize = 0;
    while (pos < headers.len) {
        const line_end = mem.indexOf(u8, headers[pos..], "\r\n") orelse headers.len - pos;
        const line = headers[pos .. pos + line_end];
        if (line.len > 16) { // "Content-Length: " = 16 chars
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
