const std = @import("std");
const mem = std.mem;
const types = @import("types.zig");

// ── JSON Builder ────────────────────────────────────────────────────
// Comptime-powered JSON serialization. Zero heap allocations.
// Writes directly into a caller-provided buffer.
//
// Usage:
//   var buf: [4096]u8 = undefined;
//   const json = Json.stringify(&buf, my_struct);
//   _ = res.json(json);
//
// Supports: structs, arrays/slices, ints, floats, bools, strings,
//           optionals (null), enums (as strings).

pub const Json = struct {
    buf: []u8,
    pos: usize = 0,
    overflow: bool = false,

    pub fn init(buf: []u8) Json {
        return .{ .buf = buf };
    }

    /// Serialize any value to JSON, return the written slice.
    /// Returns null if buffer overflow.
    pub fn stringify(buf: []u8, value: anytype) ?[]const u8 {
        var j = Json.init(buf);
        j.write(value);
        if (j.overflow) return null;
        return j.buf[0..j.pos];
    }

    /// Write a value as JSON
    pub fn write(self: *Json, value: anytype) void {
        const T = @TypeOf(value);
        const info = @typeInfo(T);

        switch (info) {
            .null => self.writeRaw("null"),
            .void => self.writeRaw("null"),
            .bool => self.writeRaw(if (value) "true" else "false"),
            .int, .comptime_int => self.writeInt(value),
            .float, .comptime_float => self.writeFloat(value),
            .optional => {
                if (value) |v| {
                    self.write(v);
                } else {
                    self.writeRaw("null");
                }
            },
            .@"enum" => {
                self.writeByte('"');
                self.writeRaw(@tagName(value));
                self.writeByte('"');
            },
            .pointer => |ptr| {
                switch (ptr.size) {
                    .slice => {
                        if (ptr.child == u8) {
                            // []const u8 → JSON string
                            self.writeString(value);
                        } else {
                            // Other slices → JSON array
                            self.writeArray(value);
                        }
                    },
                    .one => {
                        // Pointer to single item — dereference
                        self.write(value.*);
                    },
                    else => self.writeRaw("null"),
                }
            },
            .array => |arr| {
                if (arr.child == u8) {
                    // [N]u8 → JSON string
                    self.writeString(&value);
                } else {
                    self.writeArray(&value);
                }
            },
            .@"struct" => |s| {
                if (s.is_tuple) {
                    // Tuple → JSON array
                    self.writeByte('[');
                    inline for (s.fields, 0..) |field, i| {
                        if (i > 0) self.writeByte(',');
                        self.write(@field(value, field.name));
                    }
                    self.writeByte(']');
                } else {
                    // Struct → JSON object
                    self.writeByte('{');
                    var first = true;
                    inline for (s.fields) |field| {
                        const field_val = @field(value, field.name);
                        const skip = comptime @typeInfo(field.type) == .optional;
                        if (!skip or field_val != null) {
                            if (!first) self.writeByte(',');
                            first = false;
                            self.writeByte('"');
                            self.writeRaw(field.name);
                            self.writeByte('"');
                            self.writeByte(':');
                            self.write(field_val);
                        }
                    }
                    self.writeByte('}');
                }
            },
            else => self.writeRaw("null"),
        }
    }

    // ── Writers ─────────────────────────────────────────────────────

    fn writeRaw(self: *Json, s: []const u8) void {
        if (self.overflow) return;
        if (self.pos + s.len > self.buf.len) {
            self.overflow = true;
            return;
        }
        @memcpy(self.buf[self.pos .. self.pos + s.len], s);
        self.pos += s.len;
    }

    fn writeByte(self: *Json, b: u8) void {
        if (self.overflow) return;
        if (self.pos >= self.buf.len) {
            self.overflow = true;
            return;
        }
        self.buf[self.pos] = b;
        self.pos += 1;
    }

    fn writeString(self: *Json, s: []const u8) void {
        self.writeByte('"');
        for (s) |ch| {
            switch (ch) {
                '"' => self.writeRaw("\\\""),
                '\\' => self.writeRaw("\\\\"),
                '\n' => self.writeRaw("\\n"),
                '\r' => self.writeRaw("\\r"),
                '\t' => self.writeRaw("\\t"),
                0x08 => self.writeRaw("\\b"), // backspace
                0x0C => self.writeRaw("\\f"), // form feed
                else => |c| {
                    if (c < 0x20) {
                        // Control character → \u00XX
                        self.writeRaw("\\u00");
                        self.writeByte(hexDigit(c >> 4));
                        self.writeByte(hexDigit(c & 0x0F));
                    } else {
                        self.writeByte(c);
                    }
                },
            }
        }
        self.writeByte('"');
    }

    fn writeInt(self: *Json, value: anytype) void {
        var buf: [32]u8 = undefined;
        const s = types.writeI64(&buf, @as(i64, @intCast(value)));
        self.writeRaw(s);
    }

    fn writeFloat(self: *Json, value: anytype) void {
        const f: f64 = @floatCast(value);
        // Handle special values
        if (std.math.isNan(f) or std.math.isInf(f)) {
            self.writeRaw("null");
            return;
        }
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{f}) catch {
            self.writeRaw("null");
            return;
        };
        self.writeRaw(s);
    }

    fn writeArray(self: *Json, items: anytype) void {
        self.writeByte('[');
        var first = true;
        for (items) |item| {
            if (!first) self.writeByte(',');
            first = false;
            self.write(item);
        }
        self.writeByte(']');
    }

    fn hexDigit(n: u8) u8 {
        return if (n < 10) '0' + n else 'a' + (n - 10);
    }
};

// ── JSON Object Builder ─────────────────────────────────────────────
// For building JSON manually (key-value pairs) when comptime structs
// don't fit the use case.
//
// Usage:
//   var buf: [4096]u8 = undefined;
//   var obj = JsonObject.init(&buf);
//   obj.field("name", "Alice");
//   obj.field("age", 30);
//   obj.field("active", true);
//   const json = obj.finish(); // → {"name":"Alice","age":30,"active":true}

pub const JsonObject = struct {
    inner: Json,
    first: bool = true,

    pub fn init(buf: []u8) JsonObject {
        var obj = JsonObject{ .inner = Json.init(buf) };
        obj.inner.writeByte('{');
        return obj;
    }

    /// Add a key-value pair. Value can be any type Json.write supports.
    pub fn field(self: *JsonObject, key: []const u8, value: anytype) void {
        if (!self.first) self.inner.writeByte(',');
        self.first = false;
        self.inner.writeByte('"');
        self.inner.writeRaw(key);
        self.inner.writeByte('"');
        self.inner.writeByte(':');
        self.inner.write(value);
    }

    /// Add a raw JSON value (caller responsible for valid JSON).
    pub fn rawField(self: *JsonObject, key: []const u8, raw_json: []const u8) void {
        if (!self.first) self.inner.writeByte(',');
        self.first = false;
        self.inner.writeByte('"');
        self.inner.writeRaw(key);
        self.inner.writeByte('"');
        self.inner.writeByte(':');
        self.inner.writeRaw(raw_json);
    }

    /// Close the object and return the JSON string.
    /// Returns null on overflow.
    pub fn finish(self: *JsonObject) ?[]const u8 {
        self.inner.writeByte('}');
        if (self.inner.overflow) return null;
        return self.inner.buf[0..self.inner.pos];
    }
};

// ── JSON Array Builder ──────────────────────────────────────────────

pub const JsonArray = struct {
    inner: Json,
    first: bool = true,

    pub fn init(buf: []u8) JsonArray {
        var arr = JsonArray{ .inner = Json.init(buf) };
        arr.inner.writeByte('[');
        return arr;
    }

    /// Add an element. Value can be any type Json.write supports.
    pub fn push(self: *JsonArray, value: anytype) void {
        if (!self.first) self.inner.writeByte(',');
        self.first = false;
        self.inner.write(value);
    }

    /// Add a raw JSON value.
    pub fn pushRaw(self: *JsonArray, raw_json: []const u8) void {
        if (!self.first) self.inner.writeByte(',');
        self.first = false;
        self.inner.writeRaw(raw_json);
    }

    /// Close the array and return the JSON string.
    /// Returns null on overflow.
    pub fn finish(self: *JsonArray) ?[]const u8 {
        self.inner.writeByte(']');
        if (self.inner.overflow) return null;
        return self.inner.buf[0..self.inner.pos];
    }
};
