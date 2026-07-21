//! Redis write-behind mirror over the driver-owned multiplexed transport
//! (rediz.Transport, .URING). The read path is the in-process cache
//! (crudcache.zig), Redis only carries a write-behind mirror: crud cache
//! fills SET the key, crud writes DEL it. Replies are never awaited, one
//! transport thread drains queued commands and the reply sink is a no-op.

const std = @import("std");
const zix = @import("zix");

const rediz = zix.Driver.rediz;

// --------------------------------------------------------- //

const CRUD_KEY_PREFIX = "crud:item:";

/// Mirror TTL in seconds, the write path additionally deletes the key.
const CRUD_CACHE_TTL = "1";

/// Pipeline depth per connection, matches the driver transport default.
const WINDOW = rediz.dispatch.DEFAULT_WINDOW;

/// One encoded command cap: SET crud:item:<id> <body> EX 1, body <= 256.
const CMD_MAX = 512;

/// A body larger than this skips the mirror (its command would overrun CMD_MAX).
const BODY_LIMIT = 300;

// --------------------------------------------------------- //

// Set once in init before start, read-only afterwards.
var g_io: std.Io = undefined;
var g_config: rediz.Config = undefined;
var g_enabled: bool = false;
var g_conns: usize = 4;

var g_transport: ?*rediz.Transport = null;
var g_running: std.atomic.Value(bool) = .init(false);

// --------------------------------------------------------- //

/// One queued, pre-encoded RESP command.
const Command = struct {
    len: u16 = 0,
    buf: [CMD_MAX]u8 = undefined,
};

/// Bounded queue: the postgrez shard threads enqueue, this thread drains.
const QUEUE_CAP = 8192;

var q_buf: [QUEUE_CAP]Command = undefined;
var q_head: usize = 0;
var q_tail: usize = 0;
var q_lock: std.atomic.Value(bool) = .init(false);

fn qLock() void {
    while (q_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
}

fn qUnlock() void {
    q_lock.store(false, .release);
}

fn enqueue(bytes: []const u8) void {
    if (bytes.len > CMD_MAX) return;

    qLock();
    defer qUnlock();

    if (q_tail -% q_head >= QUEUE_CAP) return;

    const slot = &q_buf[q_tail & (QUEUE_CAP - 1)];
    @memcpy(slot.buf[0..bytes.len], bytes);
    slot.len = @intCast(bytes.len);
    q_tail +%= 1;
}

fn dequeue(out: *Command) bool {
    qLock();
    defer qUnlock();

    if (q_head == q_tail) return false;

    out.* = q_buf[q_head & (QUEUE_CAP - 1)];
    q_head +%= 1;

    return true;
}

// --------------------------------------------------------- //

/// Read REDIS_URL once at startup. Absent or malformed disables the mirror:
/// the in-process cache still serves x-cache MISS/HIT on its own.
pub fn init(process: std.process.Init) void {
    const url_text = process.environ_map.get("REDIS_URL") orelse return;

    g_config = rediz.parseUrl(url_text) catch return;
    g_config.tls = .OFF;
    g_config.dispatch_model = .URING;
    g_io = process.io;
    g_enabled = true;

    const cpu = std.Thread.getCpuCount() catch 4;
    g_conns = std.math.clamp(cpu, 4, 8);
}

pub fn enabled() bool {
    return g_enabled;
}

/// Open the multiplexed transport and spawn the thread that owns its poll
/// loop. Does nothing when REDIS_URL was absent.
pub fn start() void {
    if (!g_enabled) return;

    g_transport = rediz.Transport.open(std.heap.smp_allocator, g_io, g_config, .{
        .model = .URING,
        .conns = g_conns,
        .window = WINDOW,
        .on_reply = onReply,
    }) catch {
        g_enabled = false;
        return;
    };

    g_running.store(true, .release);

    const thread = std.Thread.spawn(.{}, transportLoop, .{}) catch {
        g_enabled = false;
        return;
    };
    thread.detach();
}

/// Mirror a crud item body under its key (cache fill). Fire-and-forget.
pub fn mirrorSet(id: i64, body: []const u8) void {
    if (!g_enabled) return;
    if (body.len > BODY_LIMIT) return;

    var key_buf: [40]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, CRUD_KEY_PREFIX ++ "{d}", .{id}) catch return;

    var cmd_buf: [CMD_MAX]u8 = undefined;
    const bytes = encode(&cmd_buf, &.{ "SET", key, body, "EX", CRUD_CACHE_TTL }) orelse return;

    enqueue(bytes);
}

/// Drop a crud item mirror by key (write invalidation). Fire-and-forget.
pub fn mirrorDel(id: i64) void {
    if (!g_enabled) return;

    var key_buf: [40]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, CRUD_KEY_PREFIX ++ "{d}", .{id}) catch return;

    var cmd_buf: [CMD_MAX]u8 = undefined;
    const bytes = encode(&cmd_buf, &.{ "DEL", key }) orelse return;

    enqueue(bytes);
}

/// Encode one RESP command into `scratch`, null when it does not fit.
fn encode(scratch: []u8, args: []const []const u8) ?[]const u8 {
    var out: std.ArrayList(u8) = .empty;

    var fixed = std.heap.FixedBufferAllocator.init(scratch);
    rediz.resp.encodeCommand(fixed.allocator(), &out, args) catch return null;

    return out.items;
}

// --------------------------------------------------------- //

/// The transport thread: drain queued commands into the transport, then poll.
/// A held-over command (the transport was full) is retried before the next
/// dequeue.
fn transportLoop() void {
    const transport = g_transport.?;

    var holdover: Command = undefined;
    var has_holdover = false;

    while (g_running.load(.acquire)) {
        var progressed = false;

        while (true) {
            var cmd: Command = undefined;
            if (has_holdover) {
                cmd = holdover;
                has_holdover = false;
            } else if (!dequeue(&cmd)) {
                break;
            }

            if (!transport.submit(cmd.buf[0..cmd.len], 0)) {
                holdover = cmd;
                has_holdover = true;
                break;
            }

            progressed = true;
        }

        if (transport.pending() > 0) {
            _ = transport.poll() catch {};
            progressed = true;
        }

        if (!progressed) idle();
    }
}

fn idle() void {
    const req = std.os.linux.timespec{ .sec = 0, .nsec = 200 * std.time.ns_per_us };

    _ = std.os.linux.nanosleep(&req, null);
}

/// Reply sink: the mirror is fire-and-forget, so a completed reply only
/// advances the pipeline and is otherwise ignored.
fn onReply(context: ?*anyopaque, tag: u64, reply: []const u8) void {
    _ = context;
    _ = tag;
    _ = reply;
}
