const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const Sha1 = std.crypto.hash.Sha1;
const base64 = std.base64.standard;

const types = @import("types.zig");
const Request = types.Request;
const Response = types.Response;

// ── WebSocket Constants ─────────────────────────────────────────────
const WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

// Opcodes (RFC 6455 §5.2)
pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
};

// Close status codes (RFC 6455 §7.4)
pub const CloseCode = enum(u16) {
    normal = 1000,
    going_away = 1001,
    protocol_error = 1002,
    unsupported_data = 1003,
    no_status = 1005,
    abnormal = 1006,
    invalid_payload = 1007,
    policy_violation = 1008,
    too_large = 1009,
    missing_extension = 1010,
    internal_error = 1011,
};

// ── WebSocket Frame ─────────────────────────────────────────────────
pub const Frame = struct {
    fin: bool,
    opcode: Opcode,
    payload: []const u8,
};

// ── Frame Parsing ───────────────────────────────────────────────────

pub const ParseResult = struct {
    frame: Frame,
    consumed: usize, // bytes consumed from input
};

/// Parse a WebSocket frame from raw bytes. Returns null if not enough data.
/// Server-side: clients MUST mask, we unmask in-place.
pub fn parseFrame(data: []u8) ?ParseResult {
    if (data.len < 2) return null;

    const fin = (data[0] & 0x80) != 0;
    const opcode_val = @as(u4, @truncate(data[0] & 0x0F));
    const opcode: Opcode = @enumFromInt(opcode_val);
    const masked = (data[1] & 0x80) != 0;
    var payload_len: u64 = data[1] & 0x7F;
    var offset: usize = 2;

    if (payload_len == 126) {
        if (data.len < 4) return null;
        payload_len = (@as(u64, data[2]) << 8) | @as(u64, data[3]);
        offset = 4;
    } else if (payload_len == 127) {
        if (data.len < 10) return null;
        payload_len = 0;
        inline for (0..8) |i| {
            payload_len |= @as(u64, data[2 + i]) << @intCast(56 - i * 8);
        }
        offset = 10;
    }

    // Limit payload size to 16MB
    if (payload_len > 16 * 1024 * 1024) return null;

    const mask_len: usize = if (masked) 4 else 0;
    const total_len = offset + mask_len + @as(usize, @intCast(payload_len));
    if (data.len < total_len) return null;

    const payload_start = offset + mask_len;
    const payload = data[payload_start..][0..@as(usize, @intCast(payload_len))];

    // Unmask in-place if masked
    if (masked) {
        const mask = data[offset..][0..4];
        for (payload, 0..) |*b, i| {
            b.* ^= mask[i % 4];
        }
    }

    return .{
        .frame = .{
            .fin = fin,
            .opcode = opcode,
            .payload = payload,
        },
        .consumed = total_len,
    };
}

// ── Frame Building ──────────────────────────────────────────────────

/// Build a WebSocket frame into buf. Server-side: no masking.
/// Returns the frame bytes or null if buffer too small.
pub fn buildFrame(buf: []u8, opcode: Opcode, payload: []const u8, fin: bool) ?[]const u8 {
    var offset: usize = 0;

    if (buf.len < 2) return null;

    buf[0] = (if (fin) @as(u8, 0x80) else @as(u8, 0)) | @as(u8, @intFromEnum(opcode));
    offset = 1;

    if (payload.len < 126) {
        buf[1] = @as(u8, @intCast(payload.len));
        offset = 2;
    } else if (payload.len <= 65535) {
        if (buf.len < 4) return null;
        buf[1] = 126;
        buf[2] = @as(u8, @truncate(payload.len >> 8));
        buf[3] = @as(u8, @truncate(payload.len));
        offset = 4;
    } else {
        if (buf.len < 10) return null;
        buf[1] = 127;
        const len64: u64 = payload.len;
        inline for (0..8) |i| {
            buf[2 + i] = @as(u8, @truncate(len64 >> @intCast(56 - i * 8)));
        }
        offset = 10;
    }

    if (buf.len < offset + payload.len) return null;

    @memcpy(buf[offset..][0..payload.len], payload);
    return buf[0 .. offset + payload.len];
}

/// Build a close frame with status code and optional reason.
pub fn buildCloseFrame(buf: []u8, code: CloseCode, reason: []const u8) ?[]const u8 {
    const reason_len = @min(reason.len, 123); // max 125 bytes total payload
    var payload_buf: [125]u8 = undefined;
    const code_val: u16 = @intFromEnum(code);
    payload_buf[0] = @as(u8, @truncate(code_val >> 8));
    payload_buf[1] = @as(u8, @truncate(code_val));
    if (reason_len > 0) {
        @memcpy(payload_buf[2..][0..reason_len], reason[0..reason_len]);
    }
    return buildFrame(buf, .close, payload_buf[0 .. 2 + reason_len], true);
}

// ── WebSocket Handshake ─────────────────────────────────────────────

/// Check if a request is a WebSocket upgrade request.
pub fn isUpgradeRequest(req: *const Request) bool {
    const upgrade = req.headers.get("Upgrade") orelse return false;
    if (!containsIgnoreCase(upgrade, "websocket")) return false;
    const conn = req.headers.get("Connection") orelse return false;
    if (!containsIgnoreCase(conn, "upgrade")) return false;
    const key = req.headers.get("Sec-WebSocket-Key") orelse return false;
    if (key.len == 0) return false;
    return true;
}

/// Build the WebSocket accept key from the client's Sec-WebSocket-Key.
pub fn acceptKey(client_key: []const u8, out: *[28]u8) void {
    var sha = Sha1.init(.{});
    sha.update(client_key);
    sha.update(WS_MAGIC);
    const hash = sha.finalResult();
    _ = base64.Encoder.encode(out, &hash);
}

/// Build a 101 Switching Protocols response for WebSocket upgrade.
/// Returns the raw HTTP response bytes, or null if buffer too small.
pub fn buildUpgradeResponse(buf: []u8, client_key: []const u8, protocol: ?[]const u8) ?[]const u8 {
    var accept_buf: [28]u8 = undefined;
    acceptKey(client_key, &accept_buf);

    var pos: usize = 0;

    const status_line = "HTTP/1.1 101 Switching Protocols\r\n";
    if (pos + status_line.len > buf.len) return null;
    @memcpy(buf[pos..][0..status_line.len], status_line);
    pos += status_line.len;

    const headers = "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ";
    if (pos + headers.len > buf.len) return null;
    @memcpy(buf[pos..][0..headers.len], headers);
    pos += headers.len;

    if (pos + 28 > buf.len) return null;
    @memcpy(buf[pos..][0..28], &accept_buf);
    pos += 28;

    if (protocol) |proto| {
        const proto_hdr = "\r\nSec-WebSocket-Protocol: ";
        if (pos + proto_hdr.len + proto.len > buf.len) return null;
        @memcpy(buf[pos..][0..proto_hdr.len], proto_hdr);
        pos += proto_hdr.len;
        @memcpy(buf[pos..][0..proto.len], proto);
        pos += proto.len;
    }

    const end = "\r\n\r\n";
    if (pos + end.len > buf.len) return null;
    @memcpy(buf[pos..][0..end.len], end);
    pos += end.len;

    return buf[0..pos];
}

// ── Helpers ─────────────────────────────────────────────────────────

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            const a = toLower(haystack[i + j]);
            const b = toLower(needle[j]);
            if (a != b) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

// ── Tests ───────────────────────────────────────────────────────────

test "WebSocket accept key" {
    // RFC 6455 §1.3 example: key "dGhlIHNhbXBsZSBub25jZQ=="
    var out: [28]u8 = undefined;
    acceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try std.testing.expectEqualStrings("IbKZVhPQR2E29juQcxKVbvlAzb0=", &out);
}

test "parseFrame — unmasked text" {
    // FIN + text opcode, length 5, no mask, "Hello"
    var data = [_]u8{ 0x81, 0x05, 'H', 'e', 'l', 'l', 'o' };
    const result = parseFrame(&data) orelse return error.ParseFailed;
    try std.testing.expect(result.frame.fin);
    try std.testing.expectEqual(Opcode.text, result.frame.opcode);
    try std.testing.expectEqualStrings("Hello", result.frame.payload);
    try std.testing.expectEqual(@as(usize, 7), result.consumed);
}

test "parseFrame — masked text" {
    // FIN + text, masked, length 5
    var data = [_]u8{
        0x81, 0x85, // FIN + text, masked, len=5
        0x37, 0xfa, 0x21, 0x3d, // mask
        0x7f, 0x9f, 0x4d, 0x51, 0x58, // masked "Hello"
    };
    const result = parseFrame(&data) orelse return error.ParseFailed;
    try std.testing.expect(result.frame.fin);
    try std.testing.expectEqual(Opcode.text, result.frame.opcode);
    try std.testing.expectEqualStrings("Hello", result.frame.payload);
    try std.testing.expectEqual(@as(usize, 11), result.consumed);
}

test "parseFrame — insufficient data" {
    var data = [_]u8{0x81};
    try std.testing.expect(parseFrame(&data) == null);
}

test "parseFrame — close frame" {
    // FIN + close, no mask, payload = status code 1000
    var data = [_]u8{ 0x88, 0x02, 0x03, 0xE8 };
    const result = parseFrame(&data) orelse return error.ParseFailed;
    try std.testing.expect(result.frame.fin);
    try std.testing.expectEqual(Opcode.close, result.frame.opcode);
    try std.testing.expectEqual(@as(usize, 2), result.frame.payload.len);
}

test "parseFrame — ping frame" {
    var data = [_]u8{ 0x89, 0x00 }; // FIN + ping, no payload
    const result = parseFrame(&data) orelse return error.ParseFailed;
    try std.testing.expect(result.frame.fin);
    try std.testing.expectEqual(Opcode.ping, result.frame.opcode);
    try std.testing.expectEqual(@as(usize, 0), result.frame.payload.len);
}

test "buildFrame — small text" {
    var buf: [256]u8 = undefined;
    const frame = buildFrame(&buf, .text, "Hello", true) orelse return error.BuildFailed;
    try std.testing.expectEqual(@as(usize, 7), frame.len);
    try std.testing.expectEqual(@as(u8, 0x81), frame[0]); // FIN + text
    try std.testing.expectEqual(@as(u8, 5), frame[1]); // len=5, no mask
    try std.testing.expectEqualStrings("Hello", frame[2..7]);
}

test "buildFrame — medium payload (126-65535)" {
    var buf: [300]u8 = undefined;
    const payload = [_]u8{'A'} ** 200;
    const frame = buildFrame(&buf, .binary, &payload, true) orelse return error.BuildFailed;
    try std.testing.expectEqual(@as(u8, 126), frame[1]); // extended length marker
    try std.testing.expectEqual(@as(usize, 4 + 200), frame.len); // 4 byte header + payload
}

test "buildCloseFrame" {
    var buf: [256]u8 = undefined;
    const frame = buildCloseFrame(&buf, .normal, "bye") orelse return error.BuildFailed;
    try std.testing.expectEqual(@as(u8, 0x88), frame[0]); // FIN + close
    try std.testing.expectEqual(@as(u8, 5), frame[1]); // 2 (code) + 3 (reason)
    // Status code 1000 = 0x03E8
    try std.testing.expectEqual(@as(u8, 0x03), frame[2]);
    try std.testing.expectEqual(@as(u8, 0xE8), frame[3]);
    try std.testing.expectEqualStrings("bye", frame[4..7]);
}

test "buildUpgradeResponse" {
    var buf: [512]u8 = undefined;
    const resp = buildUpgradeResponse(&buf, "dGhlIHNhbXBsZSBub25jZQ==", null) orelse return error.BuildFailed;

    const resp_str = resp;
    try std.testing.expect(mem.startsWith(u8, resp_str, "HTTP/1.1 101 Switching Protocols\r\n"));
    try std.testing.expect(mem.indexOf(u8, resp_str, "Upgrade: websocket\r\n") != null);
    try std.testing.expect(mem.indexOf(u8, resp_str, "Connection: Upgrade\r\n") != null);
    try std.testing.expect(mem.indexOf(u8, resp_str, "IbKZVhPQR2E29juQcxKVbvlAzb0=") != null);
    try std.testing.expect(mem.endsWith(u8, resp_str, "\r\n\r\n"));
}

test "buildUpgradeResponse with protocol" {
    var buf: [512]u8 = undefined;
    const resp = buildUpgradeResponse(&buf, "dGhlIHNhbXBsZSBub25jZQ==", "chat") orelse return error.BuildFailed;
    try std.testing.expect(mem.indexOf(u8, resp, "Sec-WebSocket-Protocol: chat\r\n") != null);
}

test "containsIgnoreCase" {
    try std.testing.expect(containsIgnoreCase("WebSocket", "websocket"));
    try std.testing.expect(containsIgnoreCase("keep-alive, Upgrade", "upgrade"));
    try std.testing.expect(!containsIgnoreCase("keep-alive", "upgrade"));
}

test "parseFrame — 16-bit extended length" {
    // FIN + text, length = 200
    var data: [204]u8 = undefined;
    data[0] = 0x81; // FIN + text
    data[1] = 126; // 16-bit extended length follows
    data[2] = 0; // length high byte
    data[3] = 200; // length low byte
    @memset(data[4..204], 'A');

    const result = parseFrame(&data) orelse return error.ParseFailed;
    try std.testing.expect(result.frame.fin);
    try std.testing.expectEqual(Opcode.text, result.frame.opcode);
    try std.testing.expectEqual(@as(usize, 200), result.frame.payload.len);
    try std.testing.expectEqual(@as(usize, 204), result.consumed);
}

test "buildFrame — continuation (fin=false)" {
    var buf: [256]u8 = undefined;
    const frame = buildFrame(&buf, .text, "part1", false) orelse return error.BuildFailed;
    try std.testing.expectEqual(@as(u8, 0x01), frame[0]); // no FIN, text opcode
}
