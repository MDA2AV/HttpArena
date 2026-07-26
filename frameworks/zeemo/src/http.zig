const std = @import("std");

pub const Method = enum { GET, POST, OTHER };

pub const Request = struct {
    method: Method = .OTHER,
    /// Path bytes including any leading '/', without query.
    path: []const u8 = &.{},
    /// Query bytes after '?', without leading '?'. Empty if no query.
    query: []const u8 = &.{},
    /// Body bytes (collected by parser).
    body: []const u8 = &.{},
    close: bool = false,
};

/// Incremental HTTP/1.1 request parser. Accumulates bytes into an internal
/// buffer across multiple recv() calls and emits a complete Request when
/// headers + body are fully parsed.
///
/// Validation requires resumability across TCP fragmentation (split request
/// line, split between headers, body split across recvs) and support for
/// both Content-Length and Transfer-Encoding: chunked bodies. After a
/// request is dispatched call `reset()` and any leftover bytes (pipelining)
/// remain at the start of the buffer.
pub const Parser = struct {
    buf: [BUF_SIZE]u8 = undefined,
    len: u32 = 0,
    /// Position up to which we've already searched for the header
    /// terminator — avoids rescanning on every recv.
    headers_scan: u32 = 0,
    headers_end: u32 = 0, // index after the \r\n\r\n terminator (0 = not yet)

    method: Method = .OTHER,
    path_start: u16 = 0,
    path_end: u16 = 0,
    query_start: u16 = 0,
    query_end: u16 = 0,

    content_length: u32 = 0,
    is_chunked: bool = false,
    close: bool = false,

    /// Body accumulator (separate from header buffer to keep header offsets
    /// valid after pipelining shifts). Sized for the validation workload
    /// (POST bodies ≤ 3 digits, JSON GET has no body).
    body: [BODY_MAX]u8 = undefined,
    body_len: u32 = 0,

    /// Chunked-decoding state machine, used only while is_chunked.
    chunk_state: ChunkState = .size,
    chunk_remaining: u32 = 0,
    /// Absolute byte position in self.buf up to which the chunked decoder
    /// has advanced. Set to headers_end when chunked mode is detected.
    chunk_pos: u32 = 0,

    /// Header-accumulation buffer. Sized to fit the largest pipelined
    /// burst the bench profiles emit: 16 requests × ~80 B headers = ~1.3 KB
    /// for the `pipelined` profile, comfortably below 2 KiB. Validation's
    /// fragmentation tests stay tiny too.
    pub const BUF_SIZE = 2048;
    /// Body buffer. Validation sends ≤ 4-byte bodies; gcannon's baseline
    /// POSTs are short integers. 512 B is well above realistic load while
    /// staying ~8× leaner than the old 4 KiB.
    pub const BODY_MAX = 512;

    const ChunkState = enum { size, size_cr, data, data_cr, data_lf, trailer_cr, trailer_lf, done };

    pub const FeedResult = union(enum) {
        need_more,
        ready: Request,
        /// Protocol error or buffer exhausted — caller must close the connection.
        protocol_error,
    };

    pub fn reset(self: *Parser, leftover_start: u32) void {
        // Move any bytes belonging to the next pipelined request to the
        // start of the buffer. After a request completes the headers occupy
        // [0..headers_end] and the consumed body bytes follow. Anything
        // beyond leftover_start is the next request.
        const leftover = self.len - leftover_start;
        if (leftover > 0) {
            std.mem.copyForwards(u8, self.buf[0..leftover], self.buf[leftover_start..self.len]);
        }
        self.len = leftover;
        self.headers_scan = 0;
        self.headers_end = 0;
        self.method = .OTHER;
        self.path_start = 0;
        self.path_end = 0;
        self.query_start = 0;
        self.query_end = 0;
        self.content_length = 0;
        self.is_chunked = false;
        self.close = false;
        self.body_len = 0;
        self.chunk_state = .size;
        self.chunk_remaining = 0;
        self.chunk_pos = 0;
    }

    /// Returns a writable slice the caller passes to recv(). After recv
    /// returns, call `feed(n)` with the byte count.
    pub fn recv_slot(self: *Parser) []u8 {
        return self.buf[self.len..];
    }

    pub fn feed(self: *Parser, n: u32) FeedResult {
        self.len += n;
        if (self.len > BUF_SIZE) return .protocol_error;

        if (self.headers_end == 0) {
            // Scan only the newly arrived bytes (plus 3 bytes of overlap to
            // catch a \r\n\r\n that straddles the previous tail).
            const start: u32 = if (self.headers_scan >= 3) self.headers_scan - 3 else 0;
            if (std.mem.indexOf(u8, self.buf[start..self.len], "\r\n\r\n")) |rel| {
                self.headers_end = start + @as(u32, @intCast(rel)) + 4;
                if (!parseRequestLineAndHeaders(self)) return .protocol_error;
            } else {
                self.headers_scan = self.len;
                return .need_more;
            }
        }

        // Body collection.
        if (self.is_chunked) {
            if (!self.advanceChunked()) return .protocol_error;
            if (self.chunk_state != .done) return .need_more;
        } else if (self.content_length > 0) {
            const have = self.len - self.headers_end;
            if (have < self.content_length) return .need_more;
            // Copy body bytes into the body buffer.
            if (self.content_length > BODY_MAX) return .protocol_error;
            @memcpy(self.body[0..self.content_length], self.buf[self.headers_end..][0..self.content_length]);
            self.body_len = self.content_length;
        }

        const path = self.buf[self.path_start..self.path_end];
        const query = self.buf[self.query_start..self.query_end];

        return .{ .ready = .{
            .method = self.method,
            .path = path,
            .query = query,
            .body = self.body[0..self.body_len],
            .close = self.close,
        } };
    }

    /// Returns the buffer offset at which any next pipelined request begins.
    pub fn consumed(self: *const Parser) u32 {
        const body_bytes: u32 = if (self.is_chunked)
            self.chunk_pos - self.headers_end
        else
            self.content_length;
        return self.headers_end + body_bytes;
    }

    fn advanceChunked(self: *Parser) bool {
        if (self.chunk_pos == 0) self.chunk_pos = self.headers_end;
        while (self.chunk_pos < self.len and self.chunk_state != .done) {
            const c = self.buf[self.chunk_pos];
            switch (self.chunk_state) {
                .size => {
                    if (c == '\r') {
                        self.chunk_state = .size_cr;
                    } else if (c == ';') {
                        // chunk-ext: skip until CR
                        self.chunk_pos += 1;
                        while (self.chunk_pos < self.len and self.buf[self.chunk_pos] != '\r')
                            self.chunk_pos += 1;
                        continue;
                    } else {
                        const d: u32 = switch (c) {
                            '0'...'9' => @as(u32, c - '0'),
                            'a'...'f' => @as(u32, c - 'a' + 10),
                            'A'...'F' => @as(u32, c - 'A' + 10),
                            else => return false,
                        };
                        self.chunk_remaining = self.chunk_remaining * 16 + d;
                    }
                },
                .size_cr => {
                    if (c != '\n') return false;
                    self.chunk_state = if (self.chunk_remaining == 0) .trailer_cr else .data;
                },
                .data => {
                    const take = @min(self.chunk_remaining, self.len - self.chunk_pos);
                    if (self.body_len + take > BODY_MAX) return false;
                    @memcpy(self.body[self.body_len..][0..take], self.buf[self.chunk_pos..][0..take]);
                    self.body_len += take;
                    self.chunk_remaining -= take;
                    self.chunk_pos += take;
                    if (self.chunk_remaining == 0) self.chunk_state = .data_cr;
                    continue;
                },
                .data_cr => {
                    if (c != '\r') return false;
                    self.chunk_state = .data_lf;
                },
                .data_lf => {
                    if (c != '\n') return false;
                    self.chunk_state = .size;
                },
                .trailer_cr => {
                    if (c != '\r') return false;
                    self.chunk_state = .trailer_lf;
                },
                .trailer_lf => {
                    if (c != '\n') return false;
                    self.chunk_state = .done;
                },
                .done => unreachable,
            }
            self.chunk_pos += 1;
        }
        return true;
    }

    fn parseRequestLineAndHeaders(self: *Parser) bool {
        // Request line: METHOD SP PATH[?QUERY] SP HTTP/1.1 CR LF
        var i: u32 = 0;
        const end = self.headers_end - 2; // exclude trailing \r\n\r\n (only need first 2 chars)

        // Method
        const method_start = i;
        while (i < end and self.buf[i] != ' ') : (i += 1) {}
        if (i == end) return false;
        const method = self.buf[method_start..i];
        if (std.mem.eql(u8, method, "GET")) {
            self.method = .GET;
        } else if (std.mem.eql(u8, method, "POST")) {
            self.method = .POST;
        } else {
            self.method = .OTHER;
        }
        i += 1; // skip space

        // Path (until SP or '?')
        self.path_start = @intCast(i);
        while (i < end and self.buf[i] != ' ' and self.buf[i] != '?') : (i += 1) {}
        self.path_end = @intCast(i);
        if (i == end) return false;
        if (self.buf[i] == '?') {
            i += 1;
            self.query_start = @intCast(i);
            while (i < end and self.buf[i] != ' ') : (i += 1) {}
            self.query_end = @intCast(i);
            if (i == end) return false;
        } else {
            self.query_start = self.path_end;
            self.query_end = self.path_end;
        }
        i += 1; // skip space

        // Skip HTTP-version
        while (i < end and self.buf[i] != '\r') : (i += 1) {}
        if (i >= end) return false;
        if (self.buf[i] != '\r' or self.buf[i + 1] != '\n') return false;
        i += 2;

        // Headers
        while (i + 1 < end) {
            // End of headers (the empty line) is excluded — headers_end - 2
            // pointed at the trailing CR of "\r\n\r\n", so we never see it.
            // Each header line: name ":" OWS value CR LF
            const name_start = i;
            while (i < end and self.buf[i] != ':') : (i += 1) {}
            if (i >= end) return false;
            const name = self.buf[name_start..i];
            i += 1; // skip ':'
            while (i < end and (self.buf[i] == ' ' or self.buf[i] == '\t')) : (i += 1) {}
            const value_start = i;
            while (i < end and self.buf[i] != '\r') : (i += 1) {}
            if (i >= end) return false;
            // Trim trailing OWS.
            var value_end = i;
            while (value_end > value_start and (self.buf[value_end - 1] == ' ' or self.buf[value_end - 1] == '\t'))
                value_end -= 1;
            const value = self.buf[value_start..value_end];

            if (eqlIgnoreAsciiCase(name, "content-length")) {
                self.content_length = std.fmt.parseInt(u32, value, 10) catch return false;
            } else if (eqlIgnoreAsciiCase(name, "transfer-encoding")) {
                if (containsTokenIgnoreCase(value, "chunked")) self.is_chunked = true;
            } else if (eqlIgnoreAsciiCase(name, "connection")) {
                if (containsTokenIgnoreCase(value, "close")) self.close = true;
            }

            if (self.buf[i] != '\r' or self.buf[i + 1] != '\n') return false;
            i += 2;
        }
        return true;
    }
};

fn eqlIgnoreAsciiCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

fn containsTokenIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (eqlIgnoreAsciiCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

test "GET baseline11 simple" {
    var p: Parser = .{};
    const data = "GET /baseline11?a=13&b=42 HTTP/1.1\r\nHost: x\r\n\r\n";
    @memcpy(p.recv_slot()[0..data.len], data);
    const r = p.feed(@intCast(data.len));
    try std.testing.expect(r == .ready);
    const req = r.ready;
    try std.testing.expectEqual(Method.GET, req.method);
    try std.testing.expectEqualStrings("/baseline11", req.path);
    try std.testing.expectEqualStrings("a=13&b=42", req.query);
    try std.testing.expectEqual(@as(usize, 0), req.body.len);
    try std.testing.expectEqual(false, req.close);
}

test "POST baseline11 content-length" {
    var p: Parser = .{};
    const data = "POST /baseline11?a=13&b=42 HTTP/1.1\r\nContent-Length: 2\r\n\r\n20";
    @memcpy(p.recv_slot()[0..data.len], data);
    const r = p.feed(@intCast(data.len));
    try std.testing.expect(r == .ready);
    try std.testing.expectEqualStrings("20", r.ready.body);
}

test "POST baseline11 fragmented" {
    var p: Parser = .{};
    const part1 = "POST /baseline11?a=13&b=42 HTTP/1.1\r\nContent-Length: 2\r\n\r\n";
    const part2 = "2";
    const part3 = "0";

    @memcpy(p.recv_slot()[0..part1.len], part1);
    try std.testing.expect(p.feed(@intCast(part1.len)) == .need_more);

    @memcpy(p.recv_slot()[0..part2.len], part2);
    try std.testing.expect(p.feed(@intCast(part2.len)) == .need_more);

    @memcpy(p.recv_slot()[0..part3.len], part3);
    const r = p.feed(@intCast(part3.len));
    try std.testing.expect(r == .ready);
    try std.testing.expectEqualStrings("20", r.ready.body);
}

test "POST baseline11 chunked" {
    var p: Parser = .{};
    const data = "POST /baseline11?a=13&b=42 HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n20\r\n0\r\n\r\n";
    @memcpy(p.recv_slot()[0..data.len], data);
    const r = p.feed(@intCast(data.len));
    try std.testing.expect(r == .ready);
    try std.testing.expectEqualStrings("20", r.ready.body);
}

test "two pipelined requests in one recv" {
    var p: Parser = .{};
    const data = "GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n";
    @memcpy(p.recv_slot()[0..data.len], data);
    const r1 = p.feed(@intCast(data.len));
    try std.testing.expect(r1 == .ready);
    try std.testing.expectEqualStrings("/a", r1.ready.path);

    // After dispatching the first, caller resets at parser.consumed() and
    // re-feeds zero bytes — the second request must already be ready.
    p.reset(p.consumed());
    try std.testing.expect(p.len > 0);
    const r2 = p.feed(0);
    try std.testing.expect(r2 == .ready);
    try std.testing.expectEqualStrings("/b", r2.ready.path);

    p.reset(p.consumed());
    try std.testing.expectEqual(@as(u32, 0), p.len);
}

test "split request line" {
    var p: Parser = .{};
    const part1 = "GET /baseli";
    const part2 = "ne11?a=13&b=42 HTTP/1.1\r\n";
    const part3 = "Host: localhost\r\nConnection: close\r\n\r\n";

    @memcpy(p.recv_slot()[0..part1.len], part1);
    try std.testing.expect(p.feed(@intCast(part1.len)) == .need_more);

    @memcpy(p.recv_slot()[0..part2.len], part2);
    try std.testing.expect(p.feed(@intCast(part2.len)) == .need_more);

    @memcpy(p.recv_slot()[0..part3.len], part3);
    const r = p.feed(@intCast(part3.len));
    try std.testing.expect(r == .ready);
    try std.testing.expectEqualStrings("/baseline11", r.ready.path);
    try std.testing.expect(r.ready.close);
}
