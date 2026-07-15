//! Redis state for the crud cache mirror. The read path is the in-process
//! cache (crudcache.zig), Redis carries a write-behind mirror of it through
//! the rediz deferred path (replies never awaited on the hot path). One
//! connection per executor thread, connected lazily, dropped on failure.

const std = @import("std");
const zix = @import("zix");

const rediz = zix.Driver.rediz;

// --------------------------------------------------------- //

const MAX_PENDING_REPLIES = 32;

// Set once in init before server.run, read-only afterwards.
var g_io: std.Io = undefined;
var g_config: rediz.Config = undefined;
var g_enabled: bool = false;

threadlocal var tl_conn: ?*rediz.Conn = null;

/// Read REDIS_URL once at startup. Absent or malformed disables the
/// mirror: the in-process cache still serves x-cache MISS/HIT on its own.
pub fn init(process: std.process.Init) void {
    const url_text = process.environ_map.get("REDIS_URL") orelse return;

    g_config = rediz.parseUrl(url_text) catch return;
    g_config.max_pending_replies = MAX_PENDING_REPLIES;
    g_io = process.io;
    g_enabled = true;
}

/// The calling worker's connection, connecting on first use.
/// Null when REDIS_URL is absent or the connect failed.
pub fn conn() ?*rediz.Conn {
    if (!g_enabled) return null;
    if (tl_conn) |existing| return existing;

    const fresh = rediz.Conn.connect(std.heap.smp_allocator, g_io, g_config) catch return null;
    tl_conn = fresh;

    return fresh;
}

/// Drop the worker's connection after a transport failure, so the next
/// request reconnects instead of reusing a broken stream.
pub fn drop() void {
    if (tl_conn) |broken| broken.deinit();

    tl_conn = null;
}
