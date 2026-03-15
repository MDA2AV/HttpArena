const std = @import("std");
const types = @import("types.zig");
const Request = types.Request;
const Response = types.Response;
const StatusCode = types.StatusCode;

// ── Error Handling ──────────────────────────────────────────────────
// Structured error responses for Blitz.
//
// Error responses use pre-computed string literals where possible
// (comptime-known status/message) and fall back to a buffer-based
// approach for dynamic messages.
//
// Usage:
//   // In a handler — convenience functions:
//   blitz.badRequest(res, "Missing 'name' field");
//   return;
//
//   // Generic:
//   blitz.sendError(res, .not_found, "User not found");

// Pre-computed error response bodies for common statuses.
// These are string literals — no allocation, no dangling pointers.

const err_400 = "{\"error\":{\"status\":400,\"message\":\"Bad Request\"}}";
const err_401 = "{\"error\":{\"status\":401,\"message\":\"Unauthorized\"}}";
const err_403 = "{\"error\":{\"status\":403,\"message\":\"Forbidden\"}}";
const err_404 = "{\"error\":{\"status\":404,\"message\":\"Not Found\"}}";
const err_405 = "{\"error\":{\"status\":405,\"message\":\"Method Not Allowed\"}}";
const err_500 = "{\"error\":{\"status\":500,\"message\":\"Internal Server Error\"}}";

/// Send a structured JSON error response.
///
///   {"error":{"status":400,"message":"Missing field"}}
///
/// Note: The message is embedded into a static-ish response format.
/// For custom messages, the body is built into the Response's write buffer.
/// For default messages (empty string), uses pre-computed responses.
pub fn sendError(res: *Response, status: StatusCode, message: []const u8) void {
    if (message.len == 0) {
        // Use pre-computed response with default message
        const body = switch (status) {
            .bad_request => err_400,
            .unauthorized => err_401,
            .forbidden => err_403,
            .not_found => err_404,
            .method_not_allowed => err_405,
            .internal_server_error => err_500,
            else => err_500,
        };
        _ = res.setStatus(status).json(body);
        return;
    }

    // Build error JSON with custom message.
    // Format: {"error":{"status":NNN,"message":"..."}}
    // We construct this as a raw HTTP response to avoid allocation.
    // The response body points to string literal parts concatenated at write time.
    //
    // For simplicity with custom messages, we use the prefix/suffix approach:
    // The body is the message itself, wrapped in JSON structure via rawResponse.
    var raw_buf: [2048]u8 = undefined;
    var pos: usize = 0;

    const prefix = "{\"error\":{\"status\":";
    @memcpy(raw_buf[pos .. pos + prefix.len], prefix);
    pos += prefix.len;

    // Write status code (3 digits)
    const code = status.code();
    raw_buf[pos] = @intCast(code / 100 + '0');
    raw_buf[pos + 1] = @intCast((code / 10) % 10 + '0');
    raw_buf[pos + 2] = @intCast(code % 10 + '0');
    pos += 3;

    const mid = ",\"message\":\"";
    @memcpy(raw_buf[pos .. pos + mid.len], mid);
    pos += mid.len;

    // Escape and write message
    for (message) |ch| {
        if (pos + 6 > raw_buf.len) break; // leave room for escapes
        switch (ch) {
            '"' => {
                raw_buf[pos] = '\\';
                raw_buf[pos + 1] = '"';
                pos += 2;
            },
            '\\' => {
                raw_buf[pos] = '\\';
                raw_buf[pos + 1] = '\\';
                pos += 2;
            },
            '\n' => {
                raw_buf[pos] = '\\';
                raw_buf[pos + 1] = 'n';
                pos += 2;
            },
            '\r' => {
                raw_buf[pos] = '\\';
                raw_buf[pos + 1] = 'r';
                pos += 2;
            },
            '\t' => {
                raw_buf[pos] = '\\';
                raw_buf[pos + 1] = 't';
                pos += 2;
            },
            else => {
                raw_buf[pos] = ch;
                pos += 1;
            },
        }
    }

    const suffix = "\"}}";
    @memcpy(raw_buf[pos .. pos + suffix.len], suffix);
    pos += suffix.len;

    // Build full HTTP response as raw (so body doesn't dangle)
    var http_buf: [4096]u8 = undefined;
    var hp: usize = 0;

    const status_line_pre = "HTTP/1.1 ";
    @memcpy(http_buf[hp .. hp + status_line_pre.len], status_line_pre);
    hp += status_line_pre.len;

    http_buf[hp] = @intCast(code / 100 + '0');
    http_buf[hp + 1] = @intCast((code / 10) % 10 + '0');
    http_buf[hp + 2] = @intCast(code % 10 + '0');
    hp += 3;

    http_buf[hp] = ' ';
    hp += 1;

    const phrase = status.phrase();
    @memcpy(http_buf[hp .. hp + phrase.len], phrase);
    hp += phrase.len;

    const headers_part = "\r\nServer: blitz\r\nContent-Type: application/json\r\nContent-Length: ";
    @memcpy(http_buf[hp .. hp + headers_part.len], headers_part);
    hp += headers_part.len;

    // Write content length
    var cl_buf: [16]u8 = undefined;
    const cl_str = types.writeUsize(&cl_buf, pos);
    @memcpy(http_buf[hp .. hp + cl_str.len], cl_str);
    hp += cl_str.len;

    const header_end = "\r\n\r\n";
    @memcpy(http_buf[hp .. hp + header_end.len], header_end);
    hp += header_end.len;

    // Copy body
    @memcpy(http_buf[hp .. hp + pos], raw_buf[0..pos]);
    hp += pos;

    // Use page_allocator to make a persistent copy (available without libc)
    const alloc = std.heap.page_allocator;
    const persistent = alloc.alloc(u8, hp) catch {
        _ = res.setStatus(status).json(err_500);
        return;
    };
    @memcpy(persistent, http_buf[0..hp]);
    _ = res.rawResponse(persistent);
}

/// Convenience: 400 Bad Request
pub fn badRequest(res: *Response, message: []const u8) void {
    sendError(res, .bad_request, message);
}

/// Convenience: 401 Unauthorized
pub fn unauthorized(res: *Response, message: []const u8) void {
    sendError(res, .unauthorized, message);
}

/// Convenience: 403 Forbidden
pub fn forbidden(res: *Response, message: []const u8) void {
    sendError(res, .forbidden, message);
}

/// Convenience: 404 Not Found
pub fn notFound(res: *Response, message: []const u8) void {
    sendError(res, .not_found, message);
}

/// Convenience: 405 Method Not Allowed
pub fn methodNotAllowed(res: *Response, message: []const u8) void {
    sendError(res, .method_not_allowed, message);
}

/// Convenience: 500 Internal Server Error
pub fn internalError(res: *Response, message: []const u8) void {
    sendError(res, .internal_server_error, message);
}

/// JSON 404 handler for use with router.notFound().
///
///   router.notFound(blitz.jsonNotFoundHandler);
///
pub fn jsonNotFoundHandler(_: *Request, res: *Response) void {
    _ = res.setStatus(.not_found).json(err_404);
}

/// JSON 405 handler.
pub fn jsonMethodNotAllowedHandler(_: *Request, res: *Response) void {
    _ = res.setStatus(.method_not_allowed).json(err_405);
}
