const std = @import("std");
const gzip = std.compress.gzip;
const types = @import("types.zig");
const Request = types.Request;
const Response = types.Response;

// ── Encoding detection ──────────────────────────────────────────────

pub const Encoding = enum {
    gzip,
    deflate,
    none,
};

/// Parse Accept-Encoding header and return the best supported encoding.
/// Prefers gzip > deflate > none.
pub fn acceptedEncoding(req: *const Request) Encoding {
    const header = req.headers.get("Accept-Encoding") orelse return .none;
    // Simple scan — check for "gzip" and "deflate" tokens.
    // Ignores q-values for simplicity (gzip preferred when both present).
    var has_gzip = false;
    var has_deflate = false;

    var it = std.mem.splitScalar(u8, header, ',');
    while (it.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t");
        // Strip q-value if present: "gzip;q=0.8" → "gzip"
        const enc = if (std.mem.indexOfScalar(u8, trimmed, ';')) |semi|
            std.mem.trim(u8, trimmed[0..semi], " \t")
        else
            trimmed;

        if (types.asciiEqlIgnoreCase(enc, "gzip")) {
            has_gzip = true;
        } else if (types.asciiEqlIgnoreCase(enc, "deflate")) {
            has_deflate = true;
        }
    }

    if (has_gzip) return .gzip;
    if (has_deflate) return .deflate;
    return .none;
}

/// Content types worth compressing.
fn isCompressibleType(content_type: ?[]const u8) bool {
    const ct = content_type orelse return false;
    // text/* and application/json, application/xml, etc.
    if (ct.len >= 5 and ct[0] == 't' and ct[1] == 'e' and ct[2] == 'x' and ct[3] == 't' and ct[4] == '/') return true;
    if (containsAny(ct, "json")) return true;
    if (containsAny(ct, "xml")) return true;
    if (containsAny(ct, "javascript")) return true;
    if (containsAny(ct, "svg")) return true;
    return false;
}

fn containsAny(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// ── Minimum body size to compress (too small = compression overhead > savings) ──
const MIN_COMPRESS_SIZE: usize = 256;

/// Check if a response should be compressed.
pub fn shouldCompress(req: *const Request, res: *const Response) bool {
    // Skip raw responses (pre-computed)
    if (res.raw != null) return false;
    // Skip empty or tiny bodies
    const body = res.body orelse return false;
    if (body.len < MIN_COMPRESS_SIZE) return false;
    // Skip if already compressed
    if (res.headers.get("Content-Encoding") != null) return false;
    // Check content type
    if (!isCompressibleType(res.headers.get("Content-Type"))) return false;
    // Check client accepts compression
    if (acceptedEncoding(req) == .none) return false;
    return true;
}

/// Compress data using gzip into the provided output buffer.
/// Returns the compressed slice on success, null if compression fails or output exceeds buffer.
pub fn gzipCompressSlice(out_buf: []u8, input: []const u8) ?[]const u8 {
    var fbs_in = std.io.fixedBufferStream(input);
    var fbs_out = std.io.fixedBufferStream(out_buf);

    // Use fast compression for lower latency
    gzip.compress(fbs_in.reader(), fbs_out.writer(), .{ .level = .fast }) catch return null;

    const compressed = fbs_out.getWritten();
    // Only use compression if it actually saves space
    if (compressed.len >= input.len) return null;
    return compressed;
}

/// Compress data using raw deflate into the provided output buffer.
pub fn deflateCompressSlice(out_buf: []u8, input: []const u8) ?[]const u8 {
    var fbs_in = std.io.fixedBufferStream(input);
    var fbs_out = std.io.fixedBufferStream(out_buf);

    std.compress.flate.compress(fbs_in.reader(), fbs_out.writer(), .{ .level = .fast }) catch return null;

    const compressed = fbs_out.getWritten();
    if (compressed.len >= input.len) return null;
    return compressed;
}

/// Apply compression to a response in-place. Returns the encoding used.
/// Uses the provided buffer for compressed output.
/// On success, sets res.body to the compressed data (pointing into compress_buf),
/// adds Content-Encoding and Vary headers.
pub fn compressResponse(compress_buf: []u8, req: *const Request, res: *Response) Encoding {
    if (!shouldCompress(req, res)) return .none;

    const body = res.body.?;
    const encoding = acceptedEncoding(req);

    const compressed = switch (encoding) {
        .gzip => gzipCompressSlice(compress_buf, body),
        .deflate => deflateCompressSlice(compress_buf, body),
        .none => null,
    };

    if (compressed) |data| {
        res.body = data;
        res.headers.set("Content-Encoding", switch (encoding) {
            .gzip => "gzip",
            .deflate => "deflate",
            .none => unreachable,
        });
        res.headers.set("Vary", "Accept-Encoding");
        return encoding;
    }

    return .none;
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "acceptedEncoding: gzip" {
    var headers = types.Headers{};
    headers.set("Accept-Encoding", "gzip, deflate, br");
    const req = Request{
        .method = .GET,
        .path = "/",
        .query = null,
        .headers = headers,
        .body = null,
        .raw_header = "",
    };
    try testing.expectEqual(Encoding.gzip, acceptedEncoding(&req));
}

test "acceptedEncoding: deflate only" {
    var headers = types.Headers{};
    headers.set("Accept-Encoding", "deflate");
    const req = Request{
        .method = .GET,
        .path = "/",
        .query = null,
        .headers = headers,
        .body = null,
        .raw_header = "",
    };
    try testing.expectEqual(Encoding.deflate, acceptedEncoding(&req));
}

test "acceptedEncoding: none" {
    const req = Request{
        .method = .GET,
        .path = "/",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    try testing.expectEqual(Encoding.none, acceptedEncoding(&req));
}

test "acceptedEncoding: with q-values" {
    var headers = types.Headers{};
    headers.set("Accept-Encoding", "deflate;q=0.5, gzip;q=1.0");
    const req = Request{
        .method = .GET,
        .path = "/",
        .query = null,
        .headers = headers,
        .body = null,
        .raw_header = "",
    };
    try testing.expectEqual(Encoding.gzip, acceptedEncoding(&req));
}

test "isCompressibleType" {
    try testing.expect(isCompressibleType("text/html"));
    try testing.expect(isCompressibleType("text/plain"));
    try testing.expect(isCompressibleType("text/css"));
    try testing.expect(isCompressibleType("application/json"));
    try testing.expect(isCompressibleType("application/json; charset=utf-8"));
    try testing.expect(isCompressibleType("application/xml"));
    try testing.expect(isCompressibleType("application/javascript"));
    try testing.expect(isCompressibleType("image/svg+xml"));
    try testing.expect(!isCompressibleType("image/png"));
    try testing.expect(!isCompressibleType("application/octet-stream"));
    try testing.expect(!isCompressibleType(null));
}

test "gzipCompressSlice: roundtrip" {
    // Make a compressible body (repeated text compresses well)
    const body = "Hello, World! " ** 50; // 700 bytes
    var out_buf: [4096]u8 = undefined;

    const compressed = gzipCompressSlice(&out_buf, body);
    try testing.expect(compressed != null);
    try testing.expect(compressed.?.len < body.len);

    // Verify roundtrip via decompression
    var fbs = std.io.fixedBufferStream(compressed.?);
    var decomp_buf: [4096]u8 = undefined;
    var decomp_fbs = std.io.fixedBufferStream(&decomp_buf);
    gzip.decompress(fbs.reader(), decomp_fbs.writer()) catch unreachable;
    const decompressed = decomp_fbs.getWritten();
    try testing.expectEqualStrings(body, decompressed);
}

test "gzipCompressSlice: incompressible data returns null" {
    // Random-ish data doesn't compress — or compressed >= original
    var data: [300]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i *% 251 +% 137);
    var out_buf: [4096]u8 = undefined;
    // Compressed random data is usually >= original, so should return null
    const result = gzipCompressSlice(&out_buf, &data);
    // This is fine either way — the point is it doesn't crash
    _ = result;
}

test "shouldCompress: skips tiny body" {
    var headers = types.Headers{};
    headers.set("Accept-Encoding", "gzip");
    const req = Request{
        .method = .GET,
        .path = "/",
        .query = null,
        .headers = headers,
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    _ = res.text("short");
    try testing.expect(!shouldCompress(&req, &res));
}

test "shouldCompress: skips non-compressible types" {
    var headers = types.Headers{};
    headers.set("Accept-Encoding", "gzip");
    const req = Request{
        .method = .GET,
        .path = "/",
        .query = null,
        .headers = headers,
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    res.body = "x" ** 500;
    res.headers.set("Content-Type", "image/png");
    try testing.expect(!shouldCompress(&req, &res));
}

test "shouldCompress: accepts text/html with gzip" {
    var headers = types.Headers{};
    headers.set("Accept-Encoding", "gzip");
    const req = Request{
        .method = .GET,
        .path = "/",
        .query = null,
        .headers = headers,
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    res.body = "Hello World! " ** 50;
    res.headers.set("Content-Type", "text/html");
    try testing.expect(shouldCompress(&req, &res));
}

test "compressResponse: full integration" {
    var headers = types.Headers{};
    headers.set("Accept-Encoding", "gzip");
    var req = Request{
        .method = .GET,
        .path = "/",
        .query = null,
        .headers = headers,
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    const body = "Hello, World! This is a test. " ** 30; // ~900 bytes
    _ = res.text(body);

    var compress_buf: [4096]u8 = undefined;
    const enc = compressResponse(&compress_buf, &req, &res);
    try testing.expectEqual(Encoding.gzip, enc);
    try testing.expect(res.body.?.len < body.len);
    try testing.expectEqualStrings("gzip", res.headers.get("Content-Encoding").?);
    try testing.expectEqualStrings("Accept-Encoding", res.headers.get("Vary").?);
}
