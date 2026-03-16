const std = @import("std");
const mem = std.mem;
const query_mod = @import("query.zig");
const Query = query_mod.Query;
const body_mod = @import("body.zig");
const FormData = body_mod.FormData;
const ContentType = body_mod.ContentType;
const MultipartResult = body_mod.MultipartResult;
const cookie_mod = @import("cookie.zig");
const CookieJar = cookie_mod.CookieJar;

// ── HTTP Method ─────────────────────────────────────────────────────
pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,

    pub fn fromString(s: []const u8) ?Method {
        if (s.len < 3 or s.len > 7) return null;
        return switch (s.len) {
            3 => if (s[0] == 'G' and s[1] == 'E' and s[2] == 'T') .GET
                else if (s[0] == 'P' and s[1] == 'U' and s[2] == 'T') .PUT
                else null,
            4 => if (mem.eql(u8, s, "POST")) .POST
                else if (mem.eql(u8, s, "HEAD")) .HEAD
                else null,
            5 => if (mem.eql(u8, s, "PATCH")) .PATCH
                else null,
            6 => if (mem.eql(u8, s, "DELETE")) .DELETE
                else null,
            7 => if (mem.eql(u8, s, "OPTIONS")) .OPTIONS
                else null,
            else => null,
        };
    }
};

// ── Status Code ─────────────────────────────────────────────────────
pub const StatusCode = enum(u16) {
    ok = 200,
    created = 201,
    no_content = 204,
    moved_permanently = 301,
    found = 302,
    not_modified = 304,
    bad_request = 400,
    unauthorized = 401,
    forbidden = 403,
    not_found = 404,
    method_not_allowed = 405,
    internal_server_error = 500,
    bad_gateway = 502,
    service_unavailable = 503,

    pub fn phrase(self: StatusCode) []const u8 {
        return switch (self) {
            .ok => "OK",
            .created => "Created",
            .no_content => "No Content",
            .moved_permanently => "Moved Permanently",
            .found => "Found",
            .not_modified => "Not Modified",
            .bad_request => "Bad Request",
            .unauthorized => "Unauthorized",
            .forbidden => "Forbidden",
            .not_found => "Not Found",
            .method_not_allowed => "Method Not Allowed",
            .internal_server_error => "Internal Server Error",
            .bad_gateway => "Bad Gateway",
            .service_unavailable => "Service Unavailable",
        };
    }

    pub fn code(self: StatusCode) u16 {
        return @intFromEnum(self);
    }
};

// ── Headers ─────────────────────────────────────────────────────────
pub const Headers = struct {
    entries: [MAX_HEADERS]Entry = undefined,
    len: usize = 0,

    const MAX_HEADERS = 32;

    pub const Entry = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn get(self: *const Headers, name: []const u8) ?[]const u8 {
        for (self.entries[0..self.len]) |e| {
            if (asciiEqlIgnoreCase(e.name, name)) return e.value;
        }
        return null;
    }

    pub fn set(self: *Headers, name: []const u8, value: []const u8) void {
        // Replace existing
        for (self.entries[0..self.len]) |*e| {
            if (asciiEqlIgnoreCase(e.name, name)) {
                e.value = value;
                return;
            }
        }
        // Add new
        if (self.len < MAX_HEADERS) {
            self.entries[self.len] = .{ .name = name, .value = value };
            self.len += 1;
        }
    }

    pub fn append(self: *Headers, name: []const u8, value: []const u8) void {
        if (self.len < MAX_HEADERS) {
            self.entries[self.len] = .{ .name = name, .value = value };
            self.len += 1;
        }
    }
};

// ── Request ─────────────────────────────────────────────────────────
pub const Request = struct {
    method: Method,
    path: []const u8,
    query: ?[]const u8,
    headers: Headers,
    body: ?[]const u8,
    // Content-Length from headers (available even when body is discarded/streamed)
    content_length: ?usize = null,
    // Path params filled by router
    params: Params = .{},
    // Raw data for zero-copy access
    raw_header: []const u8,

    pub const Params = struct {
        keys: [8][]const u8 = undefined,
        values: [8][]const u8 = undefined,
        len: usize = 0,

        pub fn get(self: *const Params, key: []const u8) ?[]const u8 {
            for (0..self.len) |i| {
                if (mem.eql(u8, self.keys[i], key)) return self.values[i];
            }
            return null;
        }

        pub fn set(self: *Params, key: []const u8, value: []const u8) void {
            if (self.len < 8) {
                self.keys[self.len] = key;
                self.values[self.len] = value;
                self.len += 1;
            }
        }
    };

    /// Parse query string parameter by name (simple zero-copy lookup).
    pub fn queryParam(self: *const Request, name: []const u8) ?[]const u8 {
        const q = self.query orelse return null;
        var it = mem.splitScalar(u8, q, '&');
        while (it.next()) |pair| {
            if (mem.indexOfScalar(u8, pair, '=')) |eq| {
                if (mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
            }
        }
        return null;
    }

    /// Parse the full query string into a structured Query object.
    /// Supports typed access (getInt, getBool), multi-value params, iteration, and URL decoding.
    pub fn queryParsed(self: *const Request) Query {
        const q = self.query orelse return Query{};
        return Query.parse(q);
    }

    /// Parse request body as URL-encoded form data (application/x-www-form-urlencoded).
    /// Returns a FormData (Query) struct with typed access.
    pub fn formData(self: *const Request) FormData {
        const b = self.body orelse return FormData{};
        return body_mod.parseForm(b);
    }

    /// Detect the content type of the request from the Content-Type header.
    pub fn contentType(self: *const Request) ContentType {
        const ct = self.headers.get("Content-Type") orelse return .unknown;
        return body_mod.detectContentType(ct);
    }

    /// Parse request body as multipart/form-data.
    /// Extracts the boundary from Content-Type header automatically.
    pub fn multipart(self: *const Request) ?MultipartResult {
        const ct = self.headers.get("Content-Type") orelse return null;
        const boundary = body_mod.extractBoundary(ct) orelse return null;
        const b = self.body orelse return null;
        return body_mod.parseMultipart(b, boundary);
    }

    /// Parse the Cookie header into a CookieJar.
    /// Returns an empty jar if no Cookie header is present.
    pub fn cookies(self: *const Request) CookieJar {
        const header = self.headers.get("Cookie") orelse return CookieJar{};
        return cookie_mod.parseCookies(header);
    }

    /// Get a single cookie value by name (convenience shortcut).
    pub fn cookie(self: *const Request, name: []const u8) ?[]const u8 {
        const header = self.headers.get("Cookie") orelse return null;
        const jar = cookie_mod.parseCookies(header);
        return jar.get(name);
    }
};

// ── Response ────────────────────────────────────────────────────────
pub const Response = struct {
    status: StatusCode = .ok,
    headers: Headers = .{},
    body: ?[]const u8 = null,
    // For pre-computed raw responses (bypass serialization)
    raw: ?[]const u8 = null,
    // Signal that the handler performed a WebSocket upgrade
    ws_upgraded: bool = false,
    // Scratch buffer for small response bodies — avoids dangling pointers
    // when handlers use stack-allocated buffers for writeI64/writeUsize
    scratch: [128]u8 = undefined,
    scratch_len: usize = 0,

    /// Set status
    pub fn setStatus(self: *Response, s: StatusCode) *Response {
        self.status = s;
        return self;
    }

    /// Copy data into the response's scratch buffer and set body to point to it.
    /// Use this when the source data is on the handler's stack.
    pub fn textBuf(self: *Response, data: []const u8) *Response {
        if (data.len <= self.scratch.len) {
            @memcpy(self.scratch[0..data.len], data);
            self.scratch_len = data.len;
            self.body = self.scratch[0..data.len];
        } else {
            self.body = data;
        }
        self.headers.set("Content-Type", "text/plain");
        return self;
    }

    /// Set body with content type (data must outlive the response!)
    pub fn text(self: *Response, data: []const u8) *Response {
        self.body = data;
        self.headers.set("Content-Type", "text/plain");
        return self;
    }

    /// Set JSON body
    pub fn json(self: *Response, data: []const u8) *Response {
        self.body = data;
        self.headers.set("Content-Type", "application/json");
        return self;
    }

    /// Set HTML body
    pub fn html(self: *Response, data: []const u8) *Response {
        self.body = data;
        self.headers.set("Content-Type", "text/html");
        return self;
    }

    /// Set a pre-computed raw HTTP response (headers + body)
    pub fn rawResponse(self: *Response, data: []const u8) *Response {
        self.raw = data;
        return self;
    }

    /// Set a cookie on the response.
    /// Builds the Set-Cookie header value into the provided buffer.
    /// Multiple cookies use multiple Set-Cookie headers (per RFC 6265).
    pub fn setCookie(self: *Response, buf: []u8, name: []const u8, value: []const u8, opts: cookie_mod.SetCookieOpts) *Response {
        if (cookie_mod.buildSetCookie(buf, name, value, opts)) |cookie_str| {
            self.headers.append("Set-Cookie", cookie_str);
        }
        return self;
    }

    /// Delete a cookie by setting Max-Age=0.
    pub fn deleteCookie(self: *Response, buf: []u8, name: []const u8, opts: cookie_mod.SetCookieOpts) *Response {
        if (cookie_mod.buildDeleteCookie(buf, name, opts)) |cookie_str| {
            self.headers.append("Set-Cookie", cookie_str);
        }
        return self;
    }

    /// Send a redirect response.
    pub fn redirect(self: *Response, location: []const u8, status: StatusCode) *Response {
        self.status = status;
        self.headers.set("Location", location);
        self.body = "";
        return self;
    }

    /// Temporary redirect (302 Found).
    pub fn redirectTemp(self: *Response, location: []const u8) *Response {
        return self.redirect(location, .found);
    }

    /// Permanent redirect (301 Moved Permanently).
    pub fn redirectPerm(self: *Response, location: []const u8) *Response {
        return self.redirect(location, .moved_permanently);
    }

    // Pre-computed response prefix for common 200 OK text/plain responses
    const OK_TEXT_PREFIX = "HTTP/1.1 200 OK\r\nServer: blitz\r\nContent-Type: text/plain\r\nContent-Length: ";
    const OK_JSON_PREFIX = "HTTP/1.1 200 OK\r\nServer: blitz\r\nContent-Type: application/json\r\nContent-Length: ";

    /// Serialize response to writer.
    /// Fast path for common 200 OK with text/plain or application/json and no extra headers.
    /// Fallback path builds header into a stack buffer for minimum ArrayList appends.
    pub fn writeTo(self: *const Response, out: *std.ArrayList(u8)) void {
        if (self.raw) |r| {
            out.appendSlice(r) catch return;
            return;
        }

        const body_data = self.body orelse "";

        // Fast path: 200 OK with exactly 1 header (Content-Type) — covers 90%+ of framework responses
        if (self.status == .ok and self.headers.len == 1) {
            const ct = self.headers.entries[0].value;
            const prefix = if (ct.len == 10 and ct[0] == 't') // text/plain
                OK_TEXT_PREFIX
            else if (ct.len == 16 and ct[0] == 'a') // application/json
                OK_JSON_PREFIX
            else
                "";

            if (prefix.len > 0) {
                var cl_buf: [32]u8 = undefined;
                const cl_str = writeUsize(&cl_buf, body_data.len);
                const total = prefix.len + cl_str.len + 4 + body_data.len;
                out.ensureTotalCapacity(out.items.len + total) catch return;
                out.appendSliceAssumeCapacity(prefix);
                out.appendSliceAssumeCapacity(cl_str);
                out.appendSliceAssumeCapacity("\r\n\r\n");
                out.appendSliceAssumeCapacity(body_data);
                return;
            }
        }

        // General path: build header into stack buffer, then 2 appends
        var hdr_buf: [4096]u8 = undefined;
        var pos: usize = 0;

        // Status line
        const status_prefix = "HTTP/1.1 ";
        @memcpy(hdr_buf[pos..][0..status_prefix.len], status_prefix);
        pos += status_prefix.len;

        const code = self.status.code();
        hdr_buf[pos] = @intCast(code / 100 + '0');
        hdr_buf[pos + 1] = @intCast((code / 10) % 10 + '0');
        hdr_buf[pos + 2] = @intCast(code % 10 + '0');
        pos += 3;
        hdr_buf[pos] = ' ';
        pos += 1;

        const phrase = self.status.phrase();
        @memcpy(hdr_buf[pos..][0..phrase.len], phrase);
        pos += phrase.len;

        const server_hdr = "\r\nServer: blitz\r\n";
        @memcpy(hdr_buf[pos..][0..server_hdr.len], server_hdr);
        pos += server_hdr.len;

        for (self.headers.entries[0..self.headers.len]) |h| {
            if (pos + h.name.len + h.value.len + 4 > hdr_buf.len) break;
            @memcpy(hdr_buf[pos..][0..h.name.len], h.name);
            pos += h.name.len;
            hdr_buf[pos] = ':';
            hdr_buf[pos + 1] = ' ';
            pos += 2;
            @memcpy(hdr_buf[pos..][0..h.value.len], h.value);
            pos += h.value.len;
            hdr_buf[pos] = '\r';
            hdr_buf[pos + 1] = '\n';
            pos += 2;
        }

        const cl_hdr = "Content-Length: ";
        @memcpy(hdr_buf[pos..][0..cl_hdr.len], cl_hdr);
        pos += cl_hdr.len;

        var cl_buf: [32]u8 = undefined;
        const cl_str = writeUsize(&cl_buf, body_data.len);
        @memcpy(hdr_buf[pos..][0..cl_str.len], cl_str);
        pos += cl_str.len;

        hdr_buf[pos] = '\r';
        hdr_buf[pos + 1] = '\n';
        hdr_buf[pos + 2] = '\r';
        hdr_buf[pos + 3] = '\n';
        pos += 4;

        out.ensureTotalCapacity(out.items.len + pos + body_data.len) catch return;
        out.appendSliceAssumeCapacity(hdr_buf[0..pos]);
        out.appendSliceAssumeCapacity(body_data);
    }
};

// ── Handler type ────────────────────────────────────────────────────
pub const HandlerFn = *const fn (*Request, *Response) void;

// ── Middleware type ──────────────────────────────────────────────────
// Middleware returns true to continue to next middleware/handler,
// false to short-circuit (response already set, e.g. auth failure).
pub const MiddlewareFn = *const fn (*Request, *Response) bool;

// ── Utilities ───────────────────────────────────────────────────────
pub fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la: u8 = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb: u8 = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

pub fn writeUsize(buf: []u8, val: usize) []const u8 {
    var v = val;
    var i: usize = buf.len;
    if (v == 0) {
        i -= 1;
        buf[i] = '0';
    } else {
        while (v > 0) {
            i -= 1;
            buf[i] = @intCast(v % 10 + '0');
            v /= 10;
        }
    }
    return buf[i..];
}

pub fn writeI64(buf: []u8, val: i64) []const u8 {
    var v = val;
    var neg = false;
    if (v < 0) {
        neg = true;
        v = -v;
    }
    var i: usize = buf.len;
    if (v == 0) {
        i -= 1;
        buf[i] = '0';
    } else {
        while (v > 0) {
            i -= 1;
            buf[i] = @intCast(@as(u64, @intCast(@mod(v, 10))) + '0');
            v = @divTrunc(v, 10);
        }
    }
    if (neg) {
        i -= 1;
        buf[i] = '-';
    }
    return buf[i..];
}

fn writeU16(buf: *[3]u8, val: u16) []const u8 {
    buf[0] = @intCast(val / 100 + '0');
    buf[1] = @intCast((val / 10) % 10 + '0');
    buf[2] = @intCast(val % 10 + '0');
    return buf;
}
