const std = @import("std");
const mem = std.mem;

// ── Query String Parser ─────────────────────────────────────────────
// Zero-alloc query string parsing with URL decoding.
//
// Usage:
//   var q = Query.parse("name=Alice&age=30&active=true");
//   const name = q.get("name");           // "Alice"
//   const age = q.getInt("age", i64);     // 30
//   const active = q.getBool("active");   // true
//   const missing = q.get("missing");     // null
//
// URL decoding:
//   var buf: [256]u8 = undefined;
//   const decoded = Query.urlDecode(&buf, "hello%20world+foo"); // "hello world foo"

const MAX_PARAMS = 32;

pub const QueryParam = struct {
    key: []const u8,
    value: []const u8,
};

pub const Query = struct {
    params: [MAX_PARAMS]QueryParam = undefined,
    len: usize = 0,

    /// Parse a query string (the part after '?', no leading '?').
    /// All slices point into the original string (zero-copy, no URL decoding).
    /// For decoded values, use `getDecode()`.
    pub fn parse(raw: []const u8) Query {
        var q = Query{};
        if (raw.len == 0) return q;

        var it = mem.splitScalar(u8, raw, '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            if (q.len >= MAX_PARAMS) break;

            if (mem.indexOfScalar(u8, pair, '=')) |eq| {
                q.params[q.len] = .{
                    .key = pair[0..eq],
                    .value = pair[eq + 1 ..],
                };
            } else {
                // Key without value (e.g., "?flag&debug")
                q.params[q.len] = .{
                    .key = pair,
                    .value = "",
                };
            }
            q.len += 1;
        }
        return q;
    }

    /// Get raw value by key (no URL decoding). Returns first match.
    pub fn get(self: *const Query, key: []const u8) ?[]const u8 {
        for (self.params[0..self.len]) |p| {
            if (mem.eql(u8, p.key, key)) return p.value;
        }
        return null;
    }

    /// Get URL-decoded value by key. Writes decoded value into buf.
    /// Returns decoded slice on success, null if key not found.
    pub fn getDecode(self: *const Query, key: []const u8, buf: []u8) ?[]const u8 {
        const raw = self.get(key) orelse return null;
        return urlDecode(buf, raw);
    }

    /// Get all values for a key (for repeated params like ?tag=a&tag=b).
    /// Returns number of values found, writes into the provided slice.
    pub fn getAll(self: *const Query, key: []const u8, out: [][]const u8) usize {
        var count: usize = 0;
        for (self.params[0..self.len]) |p| {
            if (mem.eql(u8, p.key, key)) {
                if (count < out.len) {
                    out[count] = p.value;
                    count += 1;
                }
            }
        }
        return count;
    }

    /// Get value as integer. Returns null if key missing or parse fails.
    pub fn getInt(self: *const Query, key: []const u8, comptime T: type) ?T {
        const raw = self.get(key) orelse return null;
        return std.fmt.parseInt(T, raw, 10) catch null;
    }

    /// Get value as boolean. Accepts "true"/"1"/"yes" as true, "false"/"0"/"no" as false.
    pub fn getBool(self: *const Query, key: []const u8) ?bool {
        const raw = self.get(key) orelse return null;
        if (mem.eql(u8, raw, "true") or mem.eql(u8, raw, "1") or mem.eql(u8, raw, "yes")) return true;
        if (mem.eql(u8, raw, "false") or mem.eql(u8, raw, "0") or mem.eql(u8, raw, "no")) return false;
        return null;
    }

    /// Check if a key exists (even if value is empty).
    pub fn has(self: *const Query, key: []const u8) bool {
        for (self.params[0..self.len]) |p| {
            if (mem.eql(u8, p.key, key)) return true;
        }
        return false;
    }

    /// Number of parsed parameters.
    pub fn paramCount(self: *const Query) usize {
        return self.len;
    }

    /// Iterator over all key-value pairs.
    pub fn iterator(self: *const Query) Iterator {
        return .{ .params = self.params[0..self.len], .index = 0 };
    }

    pub const Iterator = struct {
        params: []const QueryParam,
        index: usize,

        pub fn next(self: *Iterator) ?QueryParam {
            if (self.index >= self.params.len) return null;
            const p = self.params[self.index];
            self.index += 1;
            return p;
        }
    };
};

// ── URL Decoding ────────────────────────────────────────────────────
// Decodes percent-encoded strings (%XX) and '+' → ' '.
// Returns a slice of `buf` containing the decoded result, or null on error.

pub fn urlDecode(buf: []u8, input: []const u8) ?[]const u8 {
    var out: usize = 0;
    var i: usize = 0;

    while (i < input.len) {
        if (out >= buf.len) return null; // buffer overflow

        if (input[i] == '+') {
            buf[out] = ' ';
            out += 1;
            i += 1;
        } else if (input[i] == '%') {
            if (i + 2 >= input.len) return null; // truncated
            const hi = hexDigit(input[i + 1]) orelse return null;
            const lo = hexDigit(input[i + 2]) orelse return null;
            buf[out] = (hi << 4) | lo;
            out += 1;
            i += 3;
        } else {
            buf[out] = input[i];
            out += 1;
            i += 1;
        }
    }

    return buf[0..out];
}

fn hexDigit(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}
