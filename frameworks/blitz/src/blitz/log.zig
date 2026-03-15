const std = @import("std");
const posix = std.posix;
const types = @import("types.zig");
const Request = types.Request;
const Response = types.Response;

// ── Log Format ──────────────────────────────────────────────────────
pub const Format = enum {
    /// Compact human-readable: `GET /path 200 1.2ms 256B`
    text,
    /// Structured JSON: `{"method":"GET","path":"/path","status":200,...}`
    json,
};

// ── Log Level ───────────────────────────────────────────────────────
pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
    off = 4,

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
            .off => "",
        };
    }
};

// ── Logger Configuration ────────────────────────────────────────────
pub const LogConfig = struct {
    enabled: bool = false,
    format: Format = .text,
    min_level: Level = .info,
    /// Log slow requests (above this threshold in ms). 0 = disabled.
    slow_threshold_ms: u32 = 0,
};

// ── Monotonic Clock ─────────────────────────────────────────────────
pub fn now() i64 {
    const ts = posix.clock_gettime(.MONOTONIC) catch return 0;
    return ts.sec * 1_000_000_000 + ts.nsec;
}

// ── Request Logging ─────────────────────────────────────────────────

/// Log a completed request.
/// `start_ns` is the monotonic timestamp from `now()` taken before handler execution.
pub fn logRequest(config: LogConfig, req: *const Request, res: *const Response, start_ns: i64) void {
    if (!config.enabled) return;

    const elapsed_ns = now() - start_ns;
    const elapsed_us: u64 = @intCast(@divTrunc(elapsed_ns, 1000));
    const status = res.status.code();

    // Determine log level based on status
    const level: Level = if (status >= 500) .err else if (status >= 400) .warn else .info;

    // Check minimum level
    if (@intFromEnum(level) < @intFromEnum(config.min_level)) {
        // Exception: slow request logging
        if (config.slow_threshold_ms > 0) {
            const elapsed_ms = elapsed_us / 1000;
            if (elapsed_ms >= config.slow_threshold_ms) {
                // Log slow requests regardless of level
            } else return;
        } else return;
    }

    // Body size (from response)
    const body_len: usize = if (res.raw) |r| r.len else if (res.body) |b| b.len else 0;

    switch (config.format) {
        .text => logText(level, req, status, elapsed_us, body_len),
        .json => logJson(level, req, status, elapsed_us, body_len),
    }
}

// ── Text Format ─────────────────────────────────────────────────────
// Output: `INFO  GET /api/users 200 1.2ms 256B`

fn logText(level: Level, req: *const Request, status: u16, elapsed_us: u64, body_len: usize) void {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;

    // Level
    const lbl = level.label();
    if (lbl.len > 0 and pos + lbl.len + 2 <= buf.len) {
        @memcpy(buf[pos..][0..lbl.len], lbl);
        pos += lbl.len;
        buf[pos] = ' ';
        pos += 1;
        buf[pos] = ' ';
        pos += 1;
    }

    // Method
    const method = methodStr(req.method);
    if (pos + method.len + 1 <= buf.len) {
        @memcpy(buf[pos..][0..method.len], method);
        pos += method.len;
        buf[pos] = ' ';
        pos += 1;
    }

    // Path
    const path = req.path;
    const path_len = @min(path.len, buf.len - pos - 1);
    if (path_len > 0) {
        @memcpy(buf[pos..][0..path_len], path[0..path_len]);
        pos += path_len;
    }

    // Query string
    if (req.query) |q| {
        if (pos + 1 + q.len <= buf.len) {
            buf[pos] = '?';
            pos += 1;
            const qlen = @min(q.len, buf.len - pos);
            @memcpy(buf[pos..][0..qlen], q[0..qlen]);
            pos += qlen;
        }
    }

    buf[pos] = ' ';
    pos += 1;

    // Status
    if (pos + 4 <= buf.len) {
        buf[pos] = @intCast(status / 100 + '0');
        buf[pos + 1] = @intCast((status / 10) % 10 + '0');
        buf[pos + 2] = @intCast(status % 10 + '0');
        buf[pos + 3] = ' ';
        pos += 4;
    }

    // Latency — human readable
    pos = writeLatency(&buf, pos, elapsed_us);

    buf[pos] = ' ';
    pos += 1;

    // Body size
    pos = writeSize(&buf, pos, body_len);

    // Newline
    if (pos < buf.len) {
        buf[pos] = '\n';
        pos += 1;
    }

    // Write to stderr (non-blocking best-effort)
    _ = posix.write(2, buf[0..pos]) catch {};
}

// ── JSON Format ─────────────────────────────────────────────────────
// Output: `{"level":"INFO","method":"GET","path":"/api/users","status":200,"latency_us":1200,"size":256}`

fn logJson(level: Level, req: *const Request, status: u16, elapsed_us: u64, body_len: usize) void {
    var buf: [2048]u8 = undefined;
    var pos: usize = 0;

    // Open
    pos = appendStr(&buf, pos, "{\"level\":\"");
    pos = appendStr(&buf, pos, level.label());
    pos = appendStr(&buf, pos, "\",\"method\":\"");
    pos = appendStr(&buf, pos, methodStr(req.method));
    pos = appendStr(&buf, pos, "\",\"path\":\"");

    // Escape path for JSON
    pos = appendJsonStr(&buf, pos, req.path);

    // Query
    if (req.query) |q| {
        pos = appendStr(&buf, pos, "\",\"query\":\"");
        pos = appendJsonStr(&buf, pos, q);
    }

    pos = appendStr(&buf, pos, "\",\"status\":");

    // Status number
    if (pos + 3 <= buf.len) {
        buf[pos] = @intCast(status / 100 + '0');
        buf[pos + 1] = @intCast((status / 10) % 10 + '0');
        buf[pos + 2] = @intCast(status % 10 + '0');
        pos += 3;
    }

    pos = appendStr(&buf, pos, ",\"latency_us\":");
    pos = appendUint(&buf, pos, elapsed_us);

    pos = appendStr(&buf, pos, ",\"size\":");
    pos = appendUint(&buf, pos, @as(u64, body_len));

    pos = appendStr(&buf, pos, "}\n");

    _ = posix.write(2, buf[0..pos]) catch {};
}

// ── Latency formatting ──────────────────────────────────────────────

fn writeLatency(buf: *[1024]u8, start: usize, us: u64) usize {
    var pos = start;
    if (us < 1000) {
        // Microseconds: "123µs"
        pos = appendUintSmall(buf, pos, us);
        // µ is 2 bytes in UTF-8
        if (pos + 3 <= buf.len) {
            buf[pos] = 0xC2; // µ byte 1
            buf[pos + 1] = 0xB5; // µ byte 2
            buf[pos + 2] = 's';
            pos += 3;
        }
    } else if (us < 1_000_000) {
        // Milliseconds with 1 decimal: "1.2ms"
        const ms = us / 1000;
        const frac = (us % 1000) / 100;
        pos = appendUintSmall(buf, pos, ms);
        if (frac > 0 and pos + 2 <= buf.len) {
            buf[pos] = '.';
            buf[pos + 1] = @intCast(frac + '0');
            pos += 2;
        }
        if (pos + 2 <= buf.len) {
            buf[pos] = 'm';
            buf[pos + 1] = 's';
            pos += 2;
        }
    } else {
        // Seconds with 1 decimal: "1.2s"
        const s = us / 1_000_000;
        const frac = (us % 1_000_000) / 100_000;
        pos = appendUintSmall(buf, pos, s);
        if (frac > 0 and pos + 2 <= buf.len) {
            buf[pos] = '.';
            buf[pos + 1] = @intCast(frac + '0');
            pos += 2;
        }
        if (pos + 1 <= buf.len) {
            buf[pos] = 's';
            pos += 1;
        }
    }
    return pos;
}

fn writeSize(buf: *[1024]u8, start: usize, bytes: usize) usize {
    var pos = start;
    if (bytes < 1024) {
        pos = appendUintSmall(buf, pos, bytes);
        if (pos + 1 <= buf.len) {
            buf[pos] = 'B';
            pos += 1;
        }
    } else if (bytes < 1024 * 1024) {
        const kb = bytes / 1024;
        const frac = (bytes % 1024) * 10 / 1024;
        pos = appendUintSmall(buf, pos, kb);
        if (frac > 0 and pos + 2 <= buf.len) {
            buf[pos] = '.';
            buf[pos + 1] = @intCast(frac + '0');
            pos += 2;
        }
        if (pos + 2 <= buf.len) {
            buf[pos] = 'K';
            buf[pos + 1] = 'B';
            pos += 2;
        }
    } else {
        const mb = bytes / (1024 * 1024);
        const frac = (bytes % (1024 * 1024)) * 10 / (1024 * 1024);
        pos = appendUintSmall(buf, pos, mb);
        if (frac > 0 and pos + 2 <= buf.len) {
            buf[pos] = '.';
            buf[pos + 1] = @intCast(frac + '0');
            pos += 2;
        }
        if (pos + 2 <= buf.len) {
            buf[pos] = 'M';
            buf[pos + 1] = 'B';
            pos += 2;
        }
    }
    return pos;
}

// ── Utility: method string ──────────────────────────────────────────

fn methodStr(m: types.Method) []const u8 {
    return switch (m) {
        .GET => "GET",
        .POST => "POST",
        .PUT => "PUT",
        .DELETE => "DELETE",
        .PATCH => "PATCH",
        .HEAD => "HEAD",
        .OPTIONS => "OPTIONS",
    };
}

// ── Utility: append helpers ─────────────────────────────────────────

fn appendStr(buf: []u8, start: usize, s: []const u8) usize {
    const len = @min(s.len, buf.len - start);
    if (len > 0) {
        @memcpy(buf[start..][0..len], s[0..len]);
    }
    return start + len;
}

fn appendJsonStr(buf: []u8, start: usize, s: []const u8) usize {
    var pos = start;
    for (s) |ch| {
        if (pos >= buf.len - 1) break;
        switch (ch) {
            '"' => {
                if (pos + 2 <= buf.len) {
                    buf[pos] = '\\';
                    buf[pos + 1] = '"';
                    pos += 2;
                }
            },
            '\\' => {
                if (pos + 2 <= buf.len) {
                    buf[pos] = '\\';
                    buf[pos + 1] = '\\';
                    pos += 2;
                }
            },
            '\n' => {
                if (pos + 2 <= buf.len) {
                    buf[pos] = '\\';
                    buf[pos + 1] = 'n';
                    pos += 2;
                }
            },
            '\r' => {
                if (pos + 2 <= buf.len) {
                    buf[pos] = '\\';
                    buf[pos + 1] = 'r';
                    pos += 2;
                }
            },
            '\t' => {
                if (pos + 2 <= buf.len) {
                    buf[pos] = '\\';
                    buf[pos + 1] = 't';
                    pos += 2;
                }
            },
            else => {
                buf[pos] = ch;
                pos += 1;
            },
        }
    }
    return pos;
}

fn appendUint(buf: []u8, start: usize, val: u64) usize {
    var tmp: [20]u8 = undefined;
    var v = val;
    var i: usize = tmp.len;
    if (v == 0) {
        i -= 1;
        tmp[i] = '0';
    } else {
        while (v > 0) {
            i -= 1;
            tmp[i] = @intCast(v % 10 + '0');
            v /= 10;
        }
    }
    const s = tmp[i..];
    return appendStr(buf, start, s);
}

fn appendUintSmall(buf: anytype, start: usize, val: anytype) usize {
    var tmp: [20]u8 = undefined;
    var v: u64 = @intCast(val);
    var i: usize = tmp.len;
    if (v == 0) {
        i -= 1;
        tmp[i] = '0';
    } else {
        while (v > 0) {
            i -= 1;
            tmp[i] = @intCast(v % 10 + '0');
            v /= 10;
        }
    }
    const s = tmp[i..];
    return appendStr(buf, start, s);
}

// ── General purpose logging ─────────────────────────────────────────

/// Log a message at a given level (for framework internal logging).
pub fn log(config: LogConfig, level: Level, msg: []const u8) void {
    if (!config.enabled) return;
    if (@intFromEnum(level) < @intFromEnum(config.min_level)) return;

    var buf: [512]u8 = undefined;
    var pos: usize = 0;

    switch (config.format) {
        .text => {
            const lbl = level.label();
            pos = appendStr(&buf, pos, lbl);
            pos = appendStr(&buf, pos, "  ");
            pos = appendStr(&buf, pos, msg);
            if (pos < buf.len) {
                buf[pos] = '\n';
                pos += 1;
            }
        },
        .json => {
            pos = appendStr(&buf, pos, "{\"level\":\"");
            pos = appendStr(&buf, pos, level.label());
            pos = appendStr(&buf, pos, "\",\"msg\":\"");
            pos = appendJsonStr(&buf, pos, msg);
            pos = appendStr(&buf, pos, "\"}\n");
        },
    }

    _ = posix.write(2, buf[0..pos]) catch {};
}

// ── Tests ───────────────────────────────────────────────────────────

test "logRequest text format does not crash" {
    const config = LogConfig{ .enabled = true, .format = .text };
    var req = Request{
        .method = .GET,
        .path = "/api/users",
        .query = "page=1&limit=10",
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    _ = res.text("hello");
    const start = now();
    logRequest(config, &req, &res, start);
}

test "logRequest json format does not crash" {
    const config = LogConfig{ .enabled = true, .format = .json };
    var req = Request{
        .method = .POST,
        .path = "/api/login",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    _ = res.setStatus(.unauthorized);
    const start = now();
    logRequest(config, &req, &res, start);
}

test "logRequest disabled is noop" {
    const config = LogConfig{ .enabled = false };
    var req = Request{
        .method = .GET,
        .path = "/",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    logRequest(config, &req, &res, 0);
}

test "now returns positive" {
    const t = now();
    try std.testing.expect(t > 0);
}

test "writeLatency microseconds" {
    var buf: [1024]u8 = undefined;
    const end = writeLatency(&buf, 0, 500);
    const s = buf[0..end];
    // Should contain "µs" (UTF-8: 0xC2 0xB5 's')
    try std.testing.expect(end > 0);
    try std.testing.expect(s[end - 1] == 's');
}

test "writeLatency milliseconds" {
    var buf: [1024]u8 = undefined;
    const end = writeLatency(&buf, 0, 1500);
    const s = buf[0..end];
    // "1.5ms"
    try std.testing.expect(end >= 4);
    try std.testing.expect(s[end - 1] == 's');
    try std.testing.expect(s[end - 2] == 'm');
}

test "writeLatency seconds" {
    var buf: [1024]u8 = undefined;
    const end = writeLatency(&buf, 0, 2_500_000);
    const s = buf[0..end];
    // "2.5s"
    try std.testing.expect(s[end - 1] == 's');
}

test "writeSize bytes" {
    var buf: [1024]u8 = undefined;
    const end = writeSize(&buf, 0, 256);
    const s = buf[0..end];
    try std.testing.expect(std.mem.eql(u8, s, "256B"));
}

test "writeSize kilobytes" {
    var buf: [1024]u8 = undefined;
    const end = writeSize(&buf, 0, 2048);
    const s = buf[0..end];
    try std.testing.expect(s[end - 1] == 'B');
    try std.testing.expect(s[end - 2] == 'K');
}

test "writeSize megabytes" {
    var buf: [1024]u8 = undefined;
    const end = writeSize(&buf, 0, 5 * 1024 * 1024);
    const s = buf[0..end];
    try std.testing.expect(std.mem.eql(u8, s, "5MB"));
}

test "log general message text" {
    const config = LogConfig{ .enabled = true, .format = .text };
    log(config, .info, "server started on port 8080");
}

test "log general message json" {
    const config = LogConfig{ .enabled = true, .format = .json };
    log(config, .warn, "connection pool exhausted");
}

test "log level filtering" {
    const config = LogConfig{ .enabled = true, .min_level = .warn };
    // These should be no-ops (below threshold)
    log(config, .debug, "should not appear");
    log(config, .info, "should not appear");
    // These should log
    log(config, .warn, "this should appear");
    log(config, .err, "this should appear");
}

test "appendJsonStr escapes special chars" {
    var buf: [64]u8 = undefined;
    const pos = appendJsonStr(&buf, 0, "hello \"world\"\ntest\\path");
    const result = buf[0..pos];
    try std.testing.expect(std.mem.indexOf(u8, result, "\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\\\\") != null);
}

test "slow request threshold" {
    // With min_level=off but slow threshold, slow requests still log
    const config = LogConfig{
        .enabled = true,
        .min_level = .off,
        .slow_threshold_ms = 1, // 1ms threshold
    };
    var req = Request{
        .method = .GET,
        .path = "/slow",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    // Pass start_ns as 0 so elapsed is large
    logRequest(config, &req, &res, 0);
}
