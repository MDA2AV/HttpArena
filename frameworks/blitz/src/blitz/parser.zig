const std = @import("std");
const mem = std.mem;
const types = @import("types.zig");
const Method = types.Method;
const Request = types.Request;
const Headers = types.Headers;

// ── HTTP/1.1 Request Parser ─────────────────────────────────────────
// Zero-copy: all slices point into the original buffer.
// Supports pipelined requests (returns total_len consumed).

pub const ParseResult = struct {
    request: Request,
    total_len: usize,
};

pub fn parse(data: []const u8) ?ParseResult {
    // Find header end
    const hdr_end = mem.indexOf(u8, data, "\r\n\r\n") orelse return null;
    const hdr = data[0..hdr_end];

    // Request line
    const req_end = mem.indexOf(u8, hdr, "\r\n") orelse return null;
    const req_line = hdr[0..req_end];

    const sp1 = mem.indexOfScalar(u8, req_line, ' ') orelse return null;
    const method_str = req_line[0..sp1];
    const method = Method.fromString(method_str) orelse return null;

    const rest = req_line[sp1 + 1 ..];
    const sp2 = mem.indexOfScalar(u8, rest, ' ') orelse return null;
    const uri = rest[0..sp2];

    var path = uri;
    var query: ?[]const u8 = null;
    if (mem.indexOfScalar(u8, uri, '?')) |qp| {
        path = uri[0..qp];
        query = uri[qp + 1 ..];
    }

    // Parse headers
    var headers = Headers{};
    var content_length: ?usize = null;
    var chunked = false;

    var line_it = mem.splitSequence(u8, hdr[req_end + 2 ..], "\r\n");
    while (line_it.next()) |line| {
        if (line.len == 0) continue;
        const colon = mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        const value = mem.trimLeft(u8, line[colon + 1 ..], " ");

        headers.append(name, value);

        // Check Content-Length
        if (name.len == 14 and types.asciiEqlIgnoreCase(name, "Content-Length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch null;
        }
        // Check Transfer-Encoding
        if (name.len == 17 and types.asciiEqlIgnoreCase(name, "Transfer-Encoding")) {
            if (value.len >= 7 and types.asciiEqlIgnoreCase(value[0..7], "chunked")) {
                chunked = true;
            }
        }
    }

    const body_start = hdr_end + 4;

    if (chunked) {
        const remaining = data[body_start..];
        if (mem.indexOf(u8, remaining, "0\r\n\r\n")) |end_pos| {
            const total = body_start + end_pos + 5;
            if (total > data.len) return null;
            const chunk_body = parseFirstChunk(remaining[0..end_pos]);
            return .{
                .request = .{
                    .method = method,
                    .path = path,
                    .query = query,
                    .headers = headers,
                    .body = chunk_body,
                    .raw_header = hdr,
                },
                .total_len = total,
            };
        }
        if (mem.indexOf(u8, remaining, "\r\n0\r\n")) |end_pos| {
            const total = body_start + end_pos + 5;
            if (total > data.len) return null;
            const chunk_body = parseFirstChunk(remaining[0..end_pos]);
            return .{
                .request = .{
                    .method = method,
                    .path = path,
                    .query = query,
                    .headers = headers,
                    .body = chunk_body,
                    .raw_header = hdr,
                },
                .total_len = total,
            };
        }
        return null;
    }

    if (content_length) |cl| {
        if (data.len < body_start + cl) return null;
        return .{
            .request = .{
                .method = method,
                .path = path,
                .query = query,
                .headers = headers,
                .body = data[body_start .. body_start + cl],
                .raw_header = hdr,
            },
            .total_len = body_start + cl,
        };
    }

    return .{
        .request = .{
            .method = method,
            .path = path,
            .query = query,
            .headers = headers,
            .body = null,
            .raw_header = hdr,
        },
        .total_len = body_start,
    };
}

fn parseFirstChunk(data: []const u8) ?[]const u8 {
    const crlf = mem.indexOf(u8, data, "\r\n") orelse return null;
    const size = std.fmt.parseInt(usize, data[0..crlf], 16) catch return null;
    if (size == 0) return "";
    const start = crlf + 2;
    if (data.len < start + size) return null;
    return data[start .. start + size];
}
