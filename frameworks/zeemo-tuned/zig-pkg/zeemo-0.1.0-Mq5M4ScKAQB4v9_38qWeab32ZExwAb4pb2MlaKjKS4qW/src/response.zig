//! Per-request response builder. Writes the body in place into a caller-
//! provided output slice with a small header gutter reserved at the head;
//! `finalize()` patches the headers in once the body length is known and
//! returns the contiguous response bytes ready for `send()`.

const std = @import("std");
const json_ser = @import("json.zig");

pub const ContentType = enum {
    text_plain,
    application_json,
    application_octet_stream,
    text_html,
    custom,

    pub fn asString(self: ContentType) []const u8 {
        return switch (self) {
            .text_plain => "text/plain",
            .application_json => "application/json",
            .application_octet_stream => "application/octet-stream",
            .text_html => "text/html; charset=utf-8",
            .custom => "application/octet-stream",
        };
    }
};

/// Bytes reserved at the head of the output buffer for the HTTP status line
/// and standard headers. Fits the worst case for our endpoints:
///     "HTTP/1.1 NNN <reason>\r\nContent-Type: application/octet-stream\r\n"
///     "Content-Length: NNNNNNNNN\r\nConnection: close\r\n\r\n"
/// Comfortably under 128 bytes.
pub const HEADER_GUTTER: u32 = 128;

pub const Response = struct {
    out: []u8,
    body_pos: u32 = HEADER_GUTTER,
    status_code: u16 = 200,
    content_type: ContentType = .text_plain,
    /// Custom Content-Type string (when `content_type == .custom`).
    custom_ct: []const u8 = "",
    /// Optional `Content-Encoding` value (e.g. "br", "gzip"). Skipped if "".
    content_encoding: []const u8 = "",
    /// Server requested to close the connection after this response. Set on
    /// request side (Connection: close header) and forwarded here at init.
    close_conn: bool = false,
    /// Bypass finalize() and have the server send these bytes directly.
    /// Used by the static handler to point at pre-baked response buffers
    /// stored elsewhere (mmap'd or arena-allocated at startup).
    pre_baked: ?[]const u8 = null,

    pub fn init(out: []u8, close_conn: bool) Response {
        return .{
            .out = out,
            .body_pos = HEADER_GUTTER,
            .close_conn = close_conn,
        };
    }

    pub fn status(self: *Response, code: u16) void {
        self.status_code = code;
    }

    /// Plain-text body. Sets Content-Type to text/plain.
    pub fn text(self: *Response, s: []const u8) !void {
        self.content_type = .text_plain;
        try self.appendBytes(s);
    }

    pub fn printText(self: *Response, comptime fmt: []const u8, args: anytype) !void {
        self.content_type = .text_plain;
        const written = std.fmt.bufPrint(self.out[self.body_pos..], fmt, args) catch return error.ResponseTooLarge;
        self.body_pos += @intCast(written.len);
    }

    /// JSON body via the comptime generic serializer.
    pub fn json(self: *Response, value: anytype) !void {
        self.content_type = .application_json;
        var w = std.Io.Writer.fixed(self.out[self.body_pos..]);
        json_ser.write(&w, value) catch return error.ResponseTooLarge;
        self.body_pos += @intCast(w.end);
    }

    /// Raw bytes with given content-type. Use for octet-stream / pre-rendered HTML / etc.
    pub fn raw(self: *Response, ct: ContentType, bytes: []const u8) !void {
        self.content_type = ct;
        try self.appendBytes(bytes);
    }

    /// Hand the server a fully pre-rendered HTTP response (status line +
    /// headers + body). The server skips finalize() and sends the slice
    /// verbatim. Used by the static handler to dispatch mmap'd file
    /// responses without copying.
    pub fn sendPreBaked(self: *Response, bytes: []const u8) void {
        self.pre_baked = bytes;
    }

    pub fn setContentEncoding(self: *Response, encoding: []const u8) void {
        self.content_encoding = encoding;
    }

    pub fn setCustomContentType(self: *Response, ct: []const u8) void {
        self.content_type = .custom;
        self.custom_ct = ct;
    }

    fn appendBytes(self: *Response, s: []const u8) !void {
        if (self.body_pos + s.len > self.out.len) return error.ResponseTooLarge;
        @memcpy(self.out[self.body_pos..][0..s.len], s);
        self.body_pos += @intCast(s.len);
    }

    /// Render the status line + headers into the head of `out`, shifting
    /// the body left into place, and return the contiguous response slice
    /// starting at `out[0]`. Called by the server after the handler returns.
    ///
    /// We can't write headers up front because their byte length depends on
    /// status_code, content_type, body_len and close — all of which may be
    /// set or modified by the handler in any order. Instead the handler
    /// writes the body starting at `HEADER_GUTTER`; finalize patches headers
    /// at `[0..H]` and memmoves the body left from `[HEADER_GUTTER..]` to
    /// `[H..]`. One left-shift memcpy per response (~80 B for baseline,
    /// ~10 KiB for JSON — comfortably within memory bandwidth).
    pub fn finalize(self: *Response) []const u8 {
        if (self.pre_baked) |bytes| return bytes;
        const body_len: u32 = self.body_pos - HEADER_GUTTER;
        var hdr_buf: [HEADER_GUTTER]u8 = undefined;
        const reason = statusReason(self.status_code);
        const ct = if (self.content_type == .custom) self.custom_ct else self.content_type.asString();
        const conn_hdr: []const u8 = if (self.close_conn) "Connection: close\r\n" else "";
        const enc_hdr_buf: [128]u8 = undefined;
        _ = enc_hdr_buf;
        var enc_hdr: [64]u8 = undefined;
        const enc_str: []const u8 = if (self.content_encoding.len > 0)
            std.fmt.bufPrint(&enc_hdr, "Content-Encoding: {s}\r\n", .{self.content_encoding}) catch ""
        else
            "";
        const hdr = std.fmt.bufPrint(
            &hdr_buf,
            "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n{s}{s}\r\n",
            .{ self.status_code, reason, ct, body_len, enc_str, conn_hdr },
        ) catch unreachable;
        const h: u32 = @intCast(hdr.len);
        if (h < HEADER_GUTTER and body_len > 0) {
            // Body lives at [HEADER_GUTTER..HEADER_GUTTER+body_len]; needs
            // to slide left to [h..h+body_len]. copyForwards is safe for
            // left-direction overlapping moves.
            std.mem.copyForwards(u8, self.out[h..][0..body_len], self.out[HEADER_GUTTER..][0..body_len]);
        }
        @memcpy(self.out[0..h], hdr);
        return self.out[0 .. h + body_len];
    }
};

fn statusReason(code: u16) []const u8 {
    return switch (code) {
        200 => "OK",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        400 => "Bad Request",
        404 => "Not Found",
        500 => "Internal Server Error",
        else => "OK",
    };
}

test "text response" {
    var buf: [256]u8 = undefined;
    var res = Response.init(&buf, false);
    try res.text("Hello");
    const bytes = res.finalize();
    try std.testing.expect(std.mem.endsWith(u8, bytes, "\r\n\r\nHello"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "Content-Type: text/plain") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "Content-Length: 5") != null);
}

test "json response" {
    var buf: [512]u8 = undefined;
    var res = Response.init(&buf, false);
    try res.json(.{ .ok = true, .n = @as(u32, 42) });
    const bytes = res.finalize();
    try std.testing.expect(std.mem.indexOf(u8, bytes, "Content-Type: application/json") != null);
    try std.testing.expect(std.mem.endsWith(u8, bytes, "{\"ok\":true,\"n\":42}"));
}

test "close header" {
    var buf: [256]u8 = undefined;
    var res = Response.init(&buf, true);
    try res.text("bye");
    const bytes = res.finalize();
    try std.testing.expect(std.mem.indexOf(u8, bytes, "Connection: close") != null);
}
