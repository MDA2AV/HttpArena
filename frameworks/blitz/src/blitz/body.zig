const std = @import("std");
const mem = std.mem;
const query_mod = @import("query.zig");

// ── Request Body Parser ─────────────────────────────────────────────
// Parses URL-encoded form bodies and provides structured access.
// Same typed interface as query string parsing.

/// Parsed form data — same structure as query params
pub const FormData = query_mod.Query;

/// Parse a URL-encoded form body (application/x-www-form-urlencoded).
/// Returns a FormData (Query) struct with typed access.
/// Zero-copy: key/value slices reference the original body string.
pub fn parseForm(body: []const u8) FormData {
    return query_mod.Query.parse(body);
}

/// Content type detection
pub const ContentType = enum {
    form_urlencoded,
    multipart,
    json,
    text,
    unknown,
};

/// Detect content type from a Content-Type header value.
pub fn detectContentType(ct: []const u8) ContentType {
    // Trim and lowercase comparison
    if (ct.len == 0) return .unknown;

    if (containsIgnoreCase(ct, "application/x-www-form-urlencoded")) return .form_urlencoded;
    if (containsIgnoreCase(ct, "multipart/form-data")) return .multipart;
    if (containsIgnoreCase(ct, "application/json")) return .json;
    if (containsIgnoreCase(ct, "text/")) return .text;
    return .unknown;
}

/// Extract multipart boundary from Content-Type header.
/// Input: "multipart/form-data; boundary=----WebKitFormBoundary..."
/// Returns: "----WebKitFormBoundary..."
pub fn extractBoundary(ct: []const u8) ?[]const u8 {
    const needle = "boundary=";
    var i: usize = 0;
    while (i + needle.len <= ct.len) : (i += 1) {
        if (asciiEqlIgnoreCase(ct[i .. i + needle.len], needle)) {
            var start = i + needle.len;
            // Strip optional quotes
            if (start < ct.len and ct[start] == '"') {
                start += 1;
                const end = mem.indexOfScalar(u8, ct[start..], '"') orelse return null;
                return ct[start .. start + end];
            }
            // Find end (semicolon, space, or end of string)
            var end = start;
            while (end < ct.len and ct[end] != ';' and ct[end] != ' ' and ct[end] != '\r' and ct[end] != '\n') {
                end += 1;
            }
            if (end > start) return ct[start..end];
            return null;
        }
    }
    return null;
}

/// A single part from a multipart body
pub const MultipartPart = struct {
    name: []const u8 = "",
    filename: ?[]const u8 = null,
    content_type: []const u8 = "",
    data: []const u8 = "",
};

/// Parse a multipart/form-data body.
/// Returns parsed parts in a fixed-size array.
/// Max 16 parts supported.
pub const MAX_PARTS = 16;

pub const MultipartResult = struct {
    parts: [MAX_PARTS]MultipartPart = undefined,
    len: usize = 0,

    pub fn get(self: *const MultipartResult, name: []const u8) ?*const MultipartPart {
        for (self.parts[0..self.len]) |*part| {
            if (mem.eql(u8, part.name, name)) return part;
        }
        return null;
    }

    pub fn getFile(self: *const MultipartResult, name: []const u8) ?*const MultipartPart {
        for (self.parts[0..self.len]) |*part| {
            if (mem.eql(u8, part.name, name) and part.filename != null) return part;
        }
        return null;
    }
};

pub fn parseMultipart(body: []const u8, boundary: []const u8) MultipartResult {
    var result = MultipartResult{};

    // Build delimiter: --boundary
    var delim_buf: [256]u8 = undefined;
    if (boundary.len + 2 > delim_buf.len) return result;
    delim_buf[0] = '-';
    delim_buf[1] = '-';
    @memcpy(delim_buf[2 .. 2 + boundary.len], boundary);
    const delim = delim_buf[0 .. 2 + boundary.len];

    // Find first delimiter
    var pos = mem.indexOf(u8, body, delim) orelse return result;
    pos += delim.len;

    while (result.len < MAX_PARTS) {
        // Skip CRLF after delimiter
        if (pos + 2 > body.len) break;
        if (body[pos] == '-' and pos + 1 < body.len and body[pos + 1] == '-') break; // closing delimiter
        if (body[pos] == '\r' and body[pos + 1] == '\n') pos += 2
        else if (body[pos] == '\n') pos += 1
        else break;

        // Parse headers until empty line
        var part = MultipartPart{};
        while (pos < body.len) {
            const line_end = mem.indexOf(u8, body[pos..], "\r\n") orelse
                mem.indexOf(u8, body[pos..], "\n") orelse break;

            const line = body[pos .. pos + line_end];
            if (line.len == 0) {
                // End of headers — skip the CRLF
                pos += line_end;
                if (pos + 2 <= body.len and body[pos] == '\r' and body[pos + 1] == '\n') pos += 2
                else if (pos + 1 <= body.len and body[pos] == '\n') pos += 1;
                break;
            }

            // Parse Content-Disposition
            if (containsIgnoreCase(line, "content-disposition")) {
                part.name = extractFieldValue(line, "name") orelse "";
                part.filename = extractFieldValue(line, "filename");
            }
            // Parse Content-Type
            if (containsIgnoreCase(line, "content-type")) {
                if (mem.indexOfScalar(u8, line, ':')) |colon| {
                    part.content_type = mem.trim(u8, line[colon + 1 ..], " \t");
                }
            }

            pos += line_end;
            if (pos + 2 <= body.len and body[pos] == '\r' and body[pos + 1] == '\n') pos += 2
            else if (pos + 1 <= body.len and body[pos] == '\n') pos += 1;
        }

        // Find next delimiter to determine body
        const next = mem.indexOf(u8, body[pos..], delim);
        if (next) |n| {
            var data_end = pos + n;
            // Strip trailing CRLF before delimiter
            if (data_end >= 2 and body[data_end - 2] == '\r' and body[data_end - 1] == '\n') {
                data_end -= 2;
            } else if (data_end >= 1 and body[data_end - 1] == '\n') {
                data_end -= 1;
            }
            part.data = body[pos..data_end];
            result.parts[result.len] = part;
            result.len += 1;
            pos = pos + n + delim.len;
        } else {
            // No more delimiters — include rest as data
            part.data = body[pos..];
            result.parts[result.len] = part;
            result.len += 1;
            break;
        }
    }

    return result;
}

/// Extract a field value from a header like: Content-Disposition: form-data; name="field"; filename="file.txt"
fn extractFieldValue(header: []const u8, field: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + field.len + 2 <= header.len) : (i += 1) {
        if (asciiEqlIgnoreCase(header[i .. i + field.len], field)) {
            var pos = i + field.len;
            // Skip optional spaces and '='
            while (pos < header.len and (header[pos] == ' ' or header[pos] == '=')) pos += 1;
            if (pos >= header.len) return null;
            // Quoted value
            if (header[pos] == '"') {
                pos += 1;
                const end = mem.indexOfScalar(u8, header[pos..], '"') orelse return null;
                return header[pos .. pos + end];
            }
            // Unquoted value (until ; or end)
            var end = pos;
            while (end < header.len and header[end] != ';' and header[end] != ' ' and header[end] != '\r') end += 1;
            if (end > pos) return header[pos..end];
        }
    }
    return null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (asciiEqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la: u8 = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb: u8 = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}
