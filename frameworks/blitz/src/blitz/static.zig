const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const posix = std.posix;

const types = @import("types.zig");
const Response = types.Response;
const StatusCode = types.StatusCode;

// ── MIME Type Detection ─────────────────────────────────────────────
// Extension-based MIME type lookup. Covers the most common web types.
// Returns "application/octet-stream" for unknown extensions.

pub fn mimeFromPath(path: []const u8) []const u8 {
    const ext = extensionOf(path);
    return mimeFromExt(ext);
}

pub fn mimeFromExt(ext: []const u8) []const u8 {
    // Fast path: most common web extensions
    if (ext.len == 0) return "application/octet-stream";

    // Lowercase comparison — extensions are typically short
    // Compare bytes directly for speed
    if (eqlExt(ext, "html") or eqlExt(ext, "htm")) return "text/html; charset=utf-8";
    if (eqlExt(ext, "css")) return "text/css; charset=utf-8";
    if (eqlExt(ext, "js") or eqlExt(ext, "mjs")) return "application/javascript; charset=utf-8";
    if (eqlExt(ext, "json")) return "application/json; charset=utf-8";
    if (eqlExt(ext, "xml")) return "application/xml; charset=utf-8";
    if (eqlExt(ext, "txt")) return "text/plain; charset=utf-8";
    if (eqlExt(ext, "csv")) return "text/csv; charset=utf-8";
    if (eqlExt(ext, "md")) return "text/markdown; charset=utf-8";

    // Images
    if (eqlExt(ext, "png")) return "image/png";
    if (eqlExt(ext, "jpg") or eqlExt(ext, "jpeg")) return "image/jpeg";
    if (eqlExt(ext, "gif")) return "image/gif";
    if (eqlExt(ext, "svg")) return "image/svg+xml";
    if (eqlExt(ext, "ico")) return "image/x-icon";
    if (eqlExt(ext, "webp")) return "image/webp";
    if (eqlExt(ext, "avif")) return "image/avif";

    // Fonts
    if (eqlExt(ext, "woff")) return "font/woff";
    if (eqlExt(ext, "woff2")) return "font/woff2";
    if (eqlExt(ext, "ttf")) return "font/ttf";
    if (eqlExt(ext, "otf")) return "font/otf";
    if (eqlExt(ext, "eot")) return "application/vnd.ms-fontobject";

    // Media
    if (eqlExt(ext, "mp3")) return "audio/mpeg";
    if (eqlExt(ext, "mp4")) return "video/mp4";
    if (eqlExt(ext, "webm")) return "video/webm";
    if (eqlExt(ext, "ogg")) return "audio/ogg";
    if (eqlExt(ext, "wav")) return "audio/wav";

    // Archives & misc
    if (eqlExt(ext, "pdf")) return "application/pdf";
    if (eqlExt(ext, "zip")) return "application/zip";
    if (eqlExt(ext, "gz") or eqlExt(ext, "gzip")) return "application/gzip";
    if (eqlExt(ext, "tar")) return "application/x-tar";
    if (eqlExt(ext, "wasm")) return "application/wasm";
    if (eqlExt(ext, "map")) return "application/json";

    return "application/octet-stream";
}

/// Extract file extension from a path (without the dot).
/// Returns empty string if no extension.
pub fn extensionOf(path: []const u8) []const u8 {
    // Find last dot after last slash
    var last_slash: usize = 0;
    var last_dot: ?usize = null;
    for (path, 0..) |c, i| {
        if (c == '/') {
            last_slash = i + 1;
            last_dot = null; // Reset dot after slash
        } else if (c == '.') {
            last_dot = i;
        }
    }
    if (last_dot) |dot| {
        if (dot + 1 < path.len) return path[dot + 1 ..];
    }
    return "";
}

// ── Path Security ───────────────────────────────────────────────────
// Sanitize and validate paths to prevent directory traversal attacks.

/// Check if a relative path is safe (no traversal above root).
/// Returns the cleaned path or null if it's trying to escape.
pub fn sanitizePath(buf: []u8, filepath: []const u8) ?[]const u8 {
    // Reject absolute paths
    if (filepath.len > 0 and filepath[0] == '/') return null;

    // Walk through segments, track depth
    var depth: i32 = 0;
    var out_pos: usize = 0;
    var it = mem.splitScalar(u8, filepath, '/');
    var first = true;

    while (it.next()) |segment| {
        // Skip empty segments (double slashes)
        if (segment.len == 0) continue;

        // Check for parent directory traversal
        if (mem.eql(u8, segment, "..")) {
            depth -= 1;
            if (depth < 0) return null; // Tried to go above root
            // Back up in output buffer — remove last segment and its preceding slash
            if (out_pos > 0) {
                // Remove the last segment's characters
                while (out_pos > 0 and buf[out_pos - 1] != '/') {
                    out_pos -= 1;
                }
                // Remove the slash before it (if any)
                if (out_pos > 0) {
                    out_pos -= 1;
                }
            }
            // Reset first flag if we backed up to the beginning
            if (out_pos == 0) first = true;
            continue;
        }

        // Skip current directory
        if (mem.eql(u8, segment, ".")) continue;

        // Reject null bytes
        for (segment) |c| {
            if (c == 0) return null;
        }

        // Add separator
        if (!first) {
            if (out_pos >= buf.len) return null;
            buf[out_pos] = '/';
            out_pos += 1;
        }
        first = false;

        // Copy segment
        if (out_pos + segment.len > buf.len) return null;
        @memcpy(buf[out_pos .. out_pos + segment.len], segment);
        out_pos += segment.len;
        depth += 1;
    }

    if (out_pos == 0) return null; // Empty path
    return buf[0..out_pos];
}

// ── Static Dir Configuration ────────────────────────────────────────

pub const StaticDirConfig = struct {
    /// Route prefix (e.g., "/static")
    prefix: []const u8,
    /// Filesystem root directory (e.g., "./public")
    root: []const u8,
    /// Whether to allow directory index (index.html)
    index: bool = true,
    /// Max file size to serve (default 50MB)
    max_file_size: usize = 50 * 1024 * 1024,
    /// Cache-Control header value (empty = no header)
    cache_control: []const u8 = "",
};

pub const MAX_STATIC_DIRS = 8;

// ── File Serving ────────────────────────────────────────────────────
// Reads a file and sets the response. Uses page_allocator for the
// file contents (framework-managed, freed after response is written).

/// Serve a file from disk. Sets response body, content-type, and status.
/// Returns true if the file was served, false if not found or error.
pub fn serveFile(
    res: *Response,
    root: []const u8,
    filepath: []const u8,
    config: StaticDirConfig,
) bool {
    // Sanitize the path
    var path_buf: [4096]u8 = undefined;
    const clean_path = sanitizePath(&path_buf, filepath) orelse {
        setNotFound(res);
        return false;
    };

    // Build full filesystem path: root + "/" + clean_path
    var full_buf: [8192]u8 = undefined;
    if (root.len + 1 + clean_path.len > full_buf.len) {
        setNotFound(res);
        return false;
    }
    @memcpy(full_buf[0..root.len], root);
    full_buf[root.len] = '/';
    @memcpy(full_buf[root.len + 1 .. root.len + 1 + clean_path.len], clean_path);
    const full_path = full_buf[0 .. root.len + 1 + clean_path.len];

    // Try to open the file
    return serveFilePath(res, full_path, clean_path, config);
}

fn serveFilePath(
    res: *Response,
    full_path: []const u8,
    display_path: []const u8,
    config: StaticDirConfig,
) bool {
    // Need null-terminated string for open/fstatat
    var path_z_buf: [8192]u8 = undefined;
    if (full_path.len >= path_z_buf.len) {
        setNotFound(res);
        return false;
    }
    @memcpy(path_z_buf[0..full_path.len], full_path);
    path_z_buf[full_path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(path_z_buf[0..full_path.len :0]);

    // Try to open the file
    const fd = posix.openZ(path_z, .{ .ACCMODE = .RDONLY }, 0) catch |err| {
        // If it's a directory and index is enabled, try index.html
        if (err == error.IsDir and config.index) {
            return tryIndex(res, full_path, config);
        }
        setNotFound(res);
        return false;
    };
    defer posix.close(fd);

    // fstat the open fd to get file info
    const stat = posix.fstat(fd) catch {
        setNotFound(res);
        return false;
    };

    // Check if it's a regular file
    const is_regular = (stat.mode & posix.S.IFMT) == posix.S.IFREG;
    if (!is_regular) {
        // If directory and index is enabled, try index.html
        const is_dir = (stat.mode & posix.S.IFMT) == posix.S.IFDIR;
        if (is_dir and config.index) {
            return tryIndex(res, full_path, config);
        }
        setNotFound(res);
        return false;
    }

    // Check file size
    const file_size: usize = @intCast(@max(stat.size, 0));
    if (file_size > config.max_file_size) {
        set413(res);
        return false;
    }

    // Read the file
    const alloc = std.heap.page_allocator;
    const contents = alloc.alloc(u8, file_size) catch {
        set500(res);
        return false;
    };

    var total_read: usize = 0;
    while (total_read < file_size) {
        const n = posix.read(fd, contents[total_read..]) catch {
            alloc.free(contents);
            set500(res);
            return false;
        };
        if (n == 0) break;
        total_read += n;
    }

    // Set response
    const mime = mimeFromPath(display_path);
    res.status = .ok;
    res.body = contents[0..total_read];
    res.headers.set("Content-Type", mime);

    // Cache control
    if (config.cache_control.len > 0) {
        res.headers.set("Cache-Control", config.cache_control);
    }

    return true;
}

fn tryIndex(res: *Response, dir_path: []const u8, config: StaticDirConfig) bool {
    const index_name = "index.html";
    var full_buf: [8192]u8 = undefined;
    const needed = dir_path.len + 1 + index_name.len;
    if (needed > full_buf.len) {
        setNotFound(res);
        return false;
    }
    @memcpy(full_buf[0..dir_path.len], dir_path);
    full_buf[dir_path.len] = '/';
    @memcpy(full_buf[dir_path.len + 1 .. needed], index_name);

    return serveFilePath(res, full_buf[0..needed], index_name, config);
}

fn setNotFound(res: *Response) void {
    res.status = .not_found;
    res.body = "Not Found";
    res.headers.set("Content-Type", "text/plain");
}

fn set413(res: *Response) void {
    // Payload Too Large — use 400 since we don't have 413 in StatusCode
    res.status = .bad_request;
    res.body = "File too large";
    res.headers.set("Content-Type", "text/plain");
}

fn set500(res: *Response) void {
    res.status = .internal_server_error;
    res.body = "Internal Server Error";
    res.headers.set("Content-Type", "text/plain");
}

// ── Utilities ───────────────────────────────────────────────────────

/// Case-insensitive extension comparison
fn eqlExt(ext: []const u8, target: []const u8) bool {
    if (ext.len != target.len) return false;
    for (ext, target) |a, b| {
        const la: u8 = if (a >= 'A' and a <= 'Z') a + 32 else a;
        if (la != b) return false;
    }
    return true;
}
