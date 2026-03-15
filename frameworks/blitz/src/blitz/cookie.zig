const std = @import("std");
const mem = std.mem;
const types = @import("types.zig");

// ── Cookie Parsing ──────────────────────────────────────────────────
// Parses the Cookie request header into name-value pairs.
// Zero-copy — slices point into the original header value.

pub const MAX_COOKIES = 32;

pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
};

pub const CookieJar = struct {
    cookies: [MAX_COOKIES]Cookie = undefined,
    len: usize = 0,

    /// Get a cookie value by name.
    pub fn get(self: *const CookieJar, name: []const u8) ?[]const u8 {
        for (self.cookies[0..self.len]) |c| {
            if (mem.eql(u8, c.name, name)) return c.value;
        }
        return null;
    }

    /// Check if a cookie exists.
    pub fn has(self: *const CookieJar, name: []const u8) bool {
        return self.get(name) != null;
    }

    /// Iterate all cookies.
    pub fn iterator(self: *const CookieJar) Iterator {
        return .{ .jar = self, .index = 0 };
    }

    pub const Iterator = struct {
        jar: *const CookieJar,
        index: usize,

        pub fn next(self: *Iterator) ?Cookie {
            if (self.index >= self.jar.len) return null;
            const c = self.jar.cookies[self.index];
            self.index += 1;
            return c;
        }
    };
};

/// Parse a Cookie header value into a CookieJar.
/// Format: "name1=value1; name2=value2; ..."
pub fn parseCookies(header: []const u8) CookieJar {
    var jar = CookieJar{};
    var rest = header;

    while (rest.len > 0 and jar.len < MAX_COOKIES) {
        // Skip leading whitespace
        while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
        if (rest.len == 0) break;

        // Find the next semicolon (or end of string)
        const semi = mem.indexOfScalar(u8, rest, ';') orelse rest.len;
        const pair = rest[0..semi];
        rest = if (semi < rest.len) rest[semi + 1 ..] else rest[rest.len..];

        // Split on '='
        if (mem.indexOfScalar(u8, pair, '=')) |eq| {
            const name = trim(pair[0..eq]);
            const value = trim(pair[eq + 1 ..]);
            if (name.len > 0) {
                jar.cookies[jar.len] = .{ .name = name, .value = value };
                jar.len += 1;
            }
        }
        // Skip cookies without '=' (malformed)
    }
    return jar;
}

// ── Set-Cookie Builder ──────────────────────────────────────────────
// Builds a Set-Cookie header value into a caller-provided buffer.

pub const SameSite = enum {
    strict,
    lax,
    none,

    pub fn string(self: SameSite) []const u8 {
        return switch (self) {
            .strict => "Strict",
            .lax => "Lax",
            .none => "None",
        };
    }
};

pub const SetCookieOpts = struct {
    max_age: ?i64 = null, // seconds
    path: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    secure: bool = false,
    http_only: bool = false,
    same_site: ?SameSite = null,
};

/// Build a Set-Cookie header value into buf.
/// Returns the slice written, or null if buffer too small.
pub fn buildSetCookie(buf: []u8, name: []const u8, value: []const u8, opts: SetCookieOpts) ?[]const u8 {
    var pos: usize = 0;

    // name=value
    if (!appendSlice(buf, &pos, name)) return null;
    if (!appendByte(buf, &pos, '=')) return null;
    if (!appendSlice(buf, &pos, value)) return null;

    // Max-Age
    if (opts.max_age) |age| {
        if (!appendSlice(buf, &pos, "; Max-Age=")) return null;
        var age_buf: [20]u8 = undefined;
        const age_str = types.writeI64(&age_buf, age);
        if (!appendSlice(buf, &pos, age_str)) return null;
    }

    // Path
    if (opts.path) |path| {
        if (!appendSlice(buf, &pos, "; Path=")) return null;
        if (!appendSlice(buf, &pos, path)) return null;
    }

    // Domain
    if (opts.domain) |domain| {
        if (!appendSlice(buf, &pos, "; Domain=")) return null;
        if (!appendSlice(buf, &pos, domain)) return null;
    }

    // Secure
    if (opts.secure) {
        if (!appendSlice(buf, &pos, "; Secure")) return null;
    }

    // HttpOnly
    if (opts.http_only) {
        if (!appendSlice(buf, &pos, "; HttpOnly")) return null;
    }

    // SameSite
    if (opts.same_site) |ss| {
        if (!appendSlice(buf, &pos, "; SameSite=")) return null;
        if (!appendSlice(buf, &pos, ss.string())) return null;
    }

    return buf[0..pos];
}

/// Build a Set-Cookie that deletes a cookie (Max-Age=0).
pub fn buildDeleteCookie(buf: []u8, name: []const u8, opts: SetCookieOpts) ?[]const u8 {
    var delete_opts = opts;
    delete_opts.max_age = 0;
    return buildSetCookie(buf, name, "", delete_opts);
}

// ── Internal helpers ────────────────────────────────────────────────

fn appendSlice(buf: []u8, pos: *usize, s: []const u8) bool {
    if (pos.* + s.len > buf.len) return false;
    @memcpy(buf[pos.*..][0..s.len], s);
    pos.* += s.len;
    return true;
}

fn appendByte(buf: []u8, pos: *usize, b: u8) bool {
    if (pos.* >= buf.len) return false;
    buf[pos.*] = b;
    pos.* += 1;
    return true;
}

fn trim(s: []const u8) []const u8 {
    return trimRight(trimLeft(s));
}

fn trimLeft(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and s[i] == ' ') i += 1;
    return s[i..];
}

fn trimRight(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and s[end - 1] == ' ') end -= 1;
    return s[0..end];
}
