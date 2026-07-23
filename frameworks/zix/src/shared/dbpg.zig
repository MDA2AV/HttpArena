//! PostgreSQL for the DB endpoints (async-db, crud) over engine-worker
//! lanes: each engine worker owns one pipelined connection
//! (postgrez.dispatch.Line) pumped by its own ring (zix.Http1.uringWatchFd),
//! so a reply decodes, renders, and writes on the core that owns the client
//! socket. Handlers build a Job and call submitJob, replies come back
//! through onLaneReply on the same worker.

const std = @import("std");
const zix = @import("zix");

const crudcache = @import("crudcache.zig");

const postgrez = zix.Driver.postgrez;
const frontend = postgrez.frontend;
const backend = postgrez.backend;
const row = postgrez.row;

// --------------------------------------------------------- //

pub const NAME_MAX = 96;
pub const CATEGORY_MAX = 48;

/// Every query returns the nine item columns, 16 bounds the decode scratch.
const MAX_COLUMNS = 16;

/// Pipeline depth per connection (driver default).
const WINDOW = postgrez.dispatch.DEFAULT_WINDOW;

/// Bytes one rendered DB body may reach before renderDbRow sheds it. A crud
/// list of 100 rows tops out near 21 KiB.
const DB_BODY_MAX = 32 * 1024;

/// In-flight ASYNC_DB scans one lane allows: line count times this. Caps how
/// many concurrent price-range scans can pile onto the server at once.
/// Swept on the isolate bench: 8 reads better than 4 on both DB cells.
const SCAN_CAP_PER_CONN = 8;

// SQL: column order is fixed here, the renderers decode cells by position.
const SQL_ASYNC_DB = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3";
const SQL_CRUD_LIST = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3"; // total = returned page size per spec, no count(*) OVER()
const SQL_CRUD_GET = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE id = $1";
const SQL_CRUD_UPSERT = "INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) VALUES ($1, $2, $3, $4, $5, true, '[]', 0, 0) ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, price = EXCLUDED.price, quantity = EXCLUDED.quantity";
const SQL_CRUD_UPDATE = "UPDATE items SET name = $2, category = $3, price = $4, quantity = $5 WHERE id = $1";

// Named prepared statements, one per SQL. Prepared on every connection at
// open, so per request only Bind plus Execute is sent.
const STMT_ASYNC_DB = "zix_async_db";
const STMT_CRUD_LIST = "zix_crud_list";
const STMT_CRUD_GET = "zix_crud_get";
const STMT_CRUD_UPSERT = "zix_crud_upsert";
const STMT_CRUD_UPDATE = "zix_crud_update";

const Prepared = struct {
    name: []const u8,
    sql: []const u8,
};

const STATEMENTS = [_]Prepared{
    .{ .name = STMT_ASYNC_DB, .sql = SQL_ASYNC_DB },
    .{ .name = STMT_CRUD_LIST, .sql = SQL_CRUD_LIST },
    .{ .name = STMT_CRUD_GET, .sql = SQL_CRUD_GET },
    .{ .name = STMT_CRUD_UPSERT, .sql = SQL_CRUD_UPSERT },
    .{ .name = STMT_CRUD_UPDATE, .sql = SQL_CRUD_UPDATE },
};

// --------------------------------------------------------- //

/// One parsed DB request. Strings are copied into fixed buffers because the
/// engine reuses its receive buffer the moment the handler returns.
pub const Job = union(enum) {
    ASYNC_DB: struct {
        fd: std.posix.fd_t,
        min: i64,
        max: i64,
        limit: i64,
    },
    CRUD_LIST: struct {
        fd: std.posix.fd_t,
        page: i64,
        limit: i64,
        category_len: u8,
        category_buf: [CATEGORY_MAX]u8,
    },
    CRUD_GET: struct {
        fd: std.posix.fd_t,
        id: i64,
    },
    CRUD_CREATE: struct {
        fd: std.posix.fd_t,
        id: i64,
        price: i64,
        quantity: i64,
        name_len: u8,
        category_len: u8,
        name_buf: [NAME_MAX]u8,
        category_buf: [CATEGORY_MAX]u8,
    },
    CRUD_UPDATE: struct {
        fd: std.posix.fd_t,
        id: i64,
        price: i64,
        quantity: i64,
        name_len: u8,
        category_len: u8,
        name_buf: [NAME_MAX]u8,
        category_buf: [CATEGORY_MAX]u8,
    },
};

fn jobFd(job: Job) std.posix.fd_t {
    return switch (job) {
        inline else => |request| request.fd,
    };
}

/// Close-marked requests must be answered before the handler returns (the
/// engine closes the fd on return). submit pumps the lane until done is set.
const Completion = struct {
    done: std.atomic.Value(bool) = .init(false),
};

/// One queued Job plus its optional close-marked completion signal.
const QueuedJob = struct {
    job: Job,
    completion: ?*Completion = null,
};

// --------------------------------------------------------- //

/// In-flight Jobs one lane tracks, above its lines times WINDOW ceiling.
const SLOT_CAP = 1024;

/// Client fds one worker can have parked mid-response at once.
const PENDING_CAP = 64;

const Slot = struct {
    job: Job = undefined,
    completion: ?*Completion = null,
};

/// One stalled client write: the unsent remainder of a response, flushed
/// non-blocking every loop pass. len zero marks the slot free.
const PendingWrite = struct {
    fd: std.posix.fd_t = 0,
    sent: usize = 0,
    len: usize = 0,
    buf: [HEAD_MAX + DB_BODY_MAX]u8 = undefined,
};

/// Parked client writes for one worker: the unsent remainder of responses
/// whose socket was full, flushed non-blocking on every lane turn.
const WritePool = struct {
    pw_slots: [PENDING_CAP]PendingWrite = @splat(.{}),
    pw_active: usize = 0,
};

// Set once in init before start, read-only afterwards.
var g_io: std.Io = undefined;
var g_config: postgrez.Config = undefined;
var g_enabled: bool = false;
var g_conns: usize = 8;
var g_open: bool = false;

// Prepared-statement bytes, encoded once in start(). Module scope because the
// lane mode opens connections lazily per worker, long after start() returned.
var g_prepare_buf: [4096]u8 = undefined;
var g_prepares: [STATEMENTS.len][]const u8 = undefined;

/// The pending-write pool owned by the current worker, set at lane creation
/// so the send helpers reach it without threading a parameter through every
/// renderer.
threadlocal var tl_pool: ?*WritePool = null;

/// Set around a close-marked reply: its delivery must block until fully
/// written because the engine worker closes the fd the moment it returns.
threadlocal var tl_write_blocking: bool = false;

// Per-worker scratch. One reply is decoded at a time on a worker, so a
// per-thread buffer set is safe.
threadlocal var db_body_buf: [DB_BODY_MAX]u8 = undefined;
threadlocal var request_buf: [8 * 1024]u8 = undefined;
threadlocal var param_scratch: [8][24]u8 = undefined;

// --------------------------------------------------------- //

/// Total DB connections for a CPU budget when DATABASE_MAX_CONN is absent.
/// The arena postgres runs max_connections=256, 64 stays well inside it.
/// Small CPU budgets (the api profiles) double up: one postgres backend per
/// worker serializes the scans there, two keeps them parallel. Larger budgets
/// stay at one per worker, where two contends (isolate-swept).
fn connsFor(cpu: usize) usize {
    if (cpu <= 4) return cpu * 2;

    return std.math.clamp(cpu, 4, 64);
}

/// A crud read may have been filled between the engine-worker miss and this
/// dequeue. Answer from the cache when so, the database is not hit twice.
///
/// Return:
/// - true when answered from the cache (Job consumed)
/// - false when the Job still needs the database
fn serveFromCache(item: QueuedJob) bool {
    tl_write_blocking = item.completion != null;
    defer tl_write_blocking = false;

    switch (item.job) {
        .CRUD_GET => |request| {
            if (crudcache.get(request.id, &db_body_buf)) |len| {
                sendCrudBody(request.fd, db_body_buf[0..len], "HIT");
                signal(item);

                return true;
            }
        },
        else => {},
    }

    return false;
}

/// Shed a Job the lane could not accept: 503 the fd and release any
/// close-request waiter.
fn shed(item: QueuedJob) void {
    tl_write_blocking = item.completion != null;
    defer tl_write_blocking = false;

    send503(jobFd(item.job));
    signal(item);
}

/// Release a close-request waiter, no-op for a keep-alive Job.
fn signal(item: QueuedJob) void {
    if (item.completion) |completion| completion.done.store(true, .release);
}

/// Route one Job to its prepared statement name.
fn stmtName(job: Job) []const u8 {
    return switch (job) {
        .ASYNC_DB => STMT_ASYNC_DB,
        .CRUD_LIST => STMT_CRUD_LIST,
        .CRUD_GET => STMT_CRUD_GET,
        .CRUD_CREATE => STMT_CRUD_UPSERT,
        .CRUD_UPDATE => STMT_CRUD_UPDATE,
    };
}

/// Encode one Job as Bind plus Describe plus Execute plus Sync against its
/// named prepared statement. Params bind as text, results come back binary.
/// The returned slice lives in request_buf, consumed by line.submit.
///
/// Return:
/// - []const u8 request bytes
/// - error.OutOfMemory when the encoding overruns request_buf
fn buildRequest(job: Job) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;

    var fixed = std.heap.FixedBufferAllocator.init(&request_buf);
    const allocator = fixed.allocator();

    var params: [5]?[]const u8 = undefined;
    switch (job) {
        .ASYNC_DB => |request| {
            params[0] = intParam(0, request.min);
            params[1] = intParam(1, request.max);
            params[2] = intParam(2, request.limit);
        },
        .CRUD_LIST => |request| {
            const offset = (request.page - 1) * request.limit;
            params[0] = request.category_buf[0..request.category_len];
            params[1] = intParam(1, request.limit);
            params[2] = intParam(2, offset);
        },
        .CRUD_GET => |request| {
            params[0] = intParam(0, request.id);
        },
        .CRUD_CREATE => |request| {
            params[0] = intParam(0, request.id);
            params[1] = request.name_buf[0..request.name_len];
            params[2] = request.category_buf[0..request.category_len];
            params[3] = intParam(3, request.price);
            params[4] = intParam(4, request.quantity);
        },
        .CRUD_UPDATE => |request| {
            params[0] = intParam(0, request.id);
            params[1] = request.name_buf[0..request.name_len];
            params[2] = request.category_buf[0..request.category_len];
            params[3] = intParam(3, request.price);
            params[4] = intParam(4, request.quantity);
        },
    }

    const param_count: usize = switch (job) {
        .ASYNC_DB, .CRUD_LIST => 3,
        .CRUD_GET => 1,
        .CRUD_CREATE, .CRUD_UPDATE => 5,
    };

    try frontend.bind(allocator, &out, "", stmtName(job), &.{}, params[0..param_count], &[_]frontend.Format{.BINARY});
    try frontend.describePortal(allocator, &out, "");
    try frontend.execute(allocator, &out, "", 0);
    try frontend.sync(allocator, &out);

    return out.items;
}

/// Text-encode an i64 parameter into slot `index` of the scratch, returning a
/// slice valid until the next buildRequest on this thread.
fn intParam(index: usize, value: i64) []const u8 {
    return std.fmt.bufPrint(&param_scratch[index], "{d}", .{value}) catch unreachable;
}

// --------------------------------------------------------- //

const RowShape = enum { ASYNC_DB, CRUD_LIST, CRUD_GET };

const RenderMeta = struct {
    id: i64 = 0,
    page: i64 = 0,
    limit: i64 = 0,
    category: []const u8 = "",
};

/// Walk a SELECT-shaped reply: capture the RowDescription columns, render each
/// DataRow with renderDbRow, and write the shaped JSON. A server error sheds
/// 503, a missing single item answers 404.
fn renderRows(reply: []const u8, fd: std.posix.fd_t, shape: RowShape, meta: RenderMeta) void {
    var columns: [MAX_COLUMNS]row.ColumnInfo = undefined;
    var column_count: usize = 0;

    var cells: [MAX_COLUMNS]?[]const u8 = undefined;

    const prefix = "{\"items\":[";
    @memcpy(db_body_buf[0..prefix.len], prefix);
    var pos: usize = prefix.len;

    var rows: usize = 0;

    var walk = MessageWalk{ .bytes = reply };
    while (walk.next() catch {
        send503(fd);
        return;
    }) |message| {
        switch (message) {
            .error_response => {
                send503(fd);
                return;
            },
            .row_description => |description| {
                column_count = 0;
                var it = description.iterator();
                while (it.next() catch null) |column| {
                    if (column_count >= MAX_COLUMNS) break;

                    columns[column_count] = .{ .name = column.name, .type_oid = column.type_oid, .format = column.format };
                    column_count += 1;
                }
            },
            .data_row => |data| {
                var count: usize = 0;
                var it = data.iterator();
                while (it.next() catch null) |cell| {
                    if (count >= MAX_COLUMNS) break;

                    cells[count] = cell;
                    count += 1;
                }

                if (shape == .CRUD_GET) {
                    const len = renderDbRow(&db_body_buf, 0, columns[0..column_count], cells[0..count]) catch {
                        send503(fd);
                        return;
                    };
                    finishCrudGet(meta.id, db_body_buf[0..len], fd);

                    return;
                }

                if (rows > 0) {
                    db_body_buf[pos] = ',';
                    pos += 1;
                }
                pos = renderDbRow(&db_body_buf, pos, columns[0..column_count], cells[0..count]) catch {
                    send503(fd);
                    return;
                };
                rows += 1;
            },
            else => {},
        }
    }

    if (shape == .CRUD_GET) {
        send404(fd);
        return;
    }

    pos = appendStr(&db_body_buf, pos, "],");
    if (shape == .CRUD_LIST) {
        pos = appendStr(&db_body_buf, pos, "\"total\":");
        pos = appendInt(&db_body_buf, pos, rows);
        pos = appendStr(&db_body_buf, pos, ",\"page\":");
        pos = appendI64(&db_body_buf, pos, meta.page);
    } else {
        pos = appendStr(&db_body_buf, pos, "\"count\":");
        pos = appendInt(&db_body_buf, pos, rows);
    }
    db_body_buf[pos] = '}';
    pos += 1;

    sendJson(fd, db_body_buf[0..pos]);
}

const WriteKind = enum { CREATE, UPDATE };

/// Drive a row-less write reply (insert or update) to ReadyForQuery. On
/// success the cached id is invalidated and a small JSON status answers, a
/// server error sheds 503.
fn finishWrite(reply: []const u8, fd: std.posix.fd_t, id: i64, kind: WriteKind) void {
    var walk = MessageWalk{ .bytes = reply };
    while (walk.next() catch {
        send503(fd);
        return;
    }) |message| {
        if (message == .error_response) {
            send503(fd);
            return;
        }
    }

    invalidateCrud(id);

    switch (kind) {
        .CREATE => sendStatus(fd, 201, "{\"status\":\"created\"}"),
        .UPDATE => sendStatus(fd, 200, "{\"status\":\"ok\"}"),
    }
}

/// Iterator over the backend messages in one framed reply (up to and
/// including ReadyForQuery).
const MessageWalk = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn next(self: *MessageWalk) !?backend.BackendMessage {
        if (self.pos + 5 > self.bytes.len) return null;

        const tag = self.bytes[self.pos];
        const length = std.mem.readInt(u32, self.bytes[self.pos + 1 ..][0..4], .big);
        if (length < 4) return error.BadMessage;

        const total = 1 + @as(usize, length);
        if (self.pos + total > self.bytes.len) return null;

        const payload = self.bytes[self.pos + 5 .. self.pos + total];
        self.pos += total;

        return try backend.decode(tag, payload);
    }
};

// --------------------------------------------------------- //

/// MISS response plus the in-process cache fill.
fn finishCrudGet(id: i64, body: []const u8, fd: std.posix.fd_t) void {
    crudcache.put(id, body);

    sendCrudBody(fd, body, "MISS");
}

/// Drop the cached crud body on every write.
fn invalidateCrud(id: i64) void {
    crudcache.remove(id);
}

// --------------------------------------------------------- //

fn cellInt(columns: []const row.ColumnInfo, cells: []const ?[]const u8, index: usize) !i64 {
    const bytes = cells[index] orelse return error.BadCell;
    const column = columns[index];

    return row.rawDecode(i64, @enumFromInt(column.type_oid), column.format, bytes);
}

fn cellBool(columns: []const row.ColumnInfo, cells: []const ?[]const u8, index: usize) !bool {
    const bytes = cells[index] orelse return error.BadCell;
    const column = columns[index];

    return row.rawDecode(bool, @enumFromInt(column.type_oid), column.format, bytes);
}

fn cellStr(columns: []const row.ColumnInfo, cells: []const ?[]const u8, index: usize) ![]const u8 {
    const bytes = cells[index] orelse return error.BadCell;
    const column = columns[index];

    return row.rawDecode([]const u8, @enumFromInt(column.type_oid), column.format, bytes);
}

fn appendStr(out: []u8, pos: usize, text: []const u8) usize {
    @memcpy(out[pos..][0..text.len], text);

    return pos + text.len;
}

fn appendInt(out: []u8, pos: usize, value: u64) usize {
    var tmp: [24]u8 = undefined;
    const rendered = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch unreachable;
    @memcpy(out[pos..][0..rendered.len], rendered);

    return pos + rendered.len;
}

fn appendI64(out: []u8, pos: usize, value: i64) usize {
    var tmp: [24]u8 = undefined;
    const rendered = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch unreachable;
    @memcpy(out[pos..][0..rendered.len], rendered);

    return pos + rendered.len;
}

/// Append a JSON string body (quotes are the caller's), escaped. Worst case
/// is 6x the input, the renderDbRow budget accounts for it.
fn appendJsonStr(out: []u8, begin: usize, value: []const u8) usize {
    const HEX = "0123456789abcdef";

    var pos = begin;
    for (value) |char| {
        switch (char) {
            '"', '\\' => {
                out[pos] = '\\';
                out[pos + 1] = char;
                pos += 2;
            },
            0x00...0x1f => {
                out[pos..][0..4].* = "\\u00".*;
                out[pos + 4] = HEX[char >> 4];
                out[pos + 5] = HEX[char & 0xf];
                pos += 6;
            },
            else => {
                out[pos] = char;
                pos += 1;
            },
        }
    }

    return pos;
}

/// Render one items row as a JSON object, cells by SQL column order. tags is
/// jsonb text, emitted raw.
fn renderDbRow(out: []u8, begin: usize, columns: []const row.ColumnInfo, cells: []const ?[]const u8) !usize {
    const name = try cellStr(columns, cells, 1);
    const category = try cellStr(columns, cells, 2);
    const tags = try cellStr(columns, cells, 6);
    if (begin + name.len * 6 + category.len * 6 + tags.len + 192 > out.len) return error.NoSpaceLeft;

    var pos = begin;
    pos = appendStr(out, pos, "{\"id\":");
    pos = appendI64(out, pos, try cellInt(columns, cells, 0));
    pos = appendStr(out, pos, ",\"name\":\"");
    pos = appendJsonStr(out, pos, name);
    pos = appendStr(out, pos, "\",\"category\":\"");
    pos = appendJsonStr(out, pos, category);
    pos = appendStr(out, pos, "\",\"price\":");
    pos = appendI64(out, pos, try cellInt(columns, cells, 3));
    pos = appendStr(out, pos, ",\"quantity\":");
    pos = appendI64(out, pos, try cellInt(columns, cells, 4));
    pos = appendStr(out, pos, ",\"active\":");
    pos = appendStr(out, pos, if (try cellBool(columns, cells, 5)) "true" else "false");
    pos = appendStr(out, pos, ",\"tags\":");
    pos = appendStr(out, pos, tags);
    pos = appendStr(out, pos, ",\"rating\":{\"score\":");
    pos = appendI64(out, pos, try cellInt(columns, cells, 7));
    pos = appendStr(out, pos, ",\"count\":");
    pos = appendI64(out, pos, try cellInt(columns, cells, 8));
    pos = appendStr(out, pos, "}}");

    return pos;
}

// --------------------------------------------------------- //

/// Bytes one response head may reach (status line, Content-Type,
/// Content-Length, Date).
const HEAD_MAX = 192;

/// Status lines for the lane-side responses, byte-matching the engine.
fn statusLine(status: u16) []const u8 {
    return switch (status) {
        200 => "HTTP/1.1 200 OK\r\n",
        201 => "HTTP/1.1 201 Created\r\n",
        404 => "HTTP/1.1 404 Not Found\r\n",
        503 => "HTTP/1.1 503 Service Unavailable\r\n",
        else => "HTTP/1.1 500 Internal Server Error\r\n",
    };
}

/// Build a response head byte-matching what the engine fd writers emit
/// (Content-Type, Content-Length, Date).
fn buildHead(buf: []u8, status: u16, content_type: []const u8, body_len: usize) []const u8 {
    var pos: usize = 0;
    pos = appendStr(buf, pos, statusLine(status));
    pos = appendStr(buf, pos, "Content-Type: ");
    pos = appendStr(buf, pos, content_type);
    pos = appendStr(buf, pos, "\r\nContent-Length: ");
    pos = appendInt(buf, pos, body_len);
    pos = appendStr(buf, pos, "\r\nDate: ");
    pos = appendStr(buf, pos, httpDate());
    pos = appendStr(buf, pos, "\r\n\r\n");

    return buf[0..pos];
}

threadlocal var date_secs: u64 = 0;
threadlocal var date_len: usize = 0;
threadlocal var date_tick: u8 = 0;
threadlocal var date_buf: [40]u8 = undefined;

/// Cached RFC 7231 date, refreshed at most once per 256 responses (the same
/// pacing as the engine's date cache).
fn httpDate() []const u8 {
    date_tick +%= 1;
    if (date_tick == 0 or date_len == 0) {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);

        const secs: u64 = if (ts.sec >= 0) @intCast(ts.sec) else 0;
        if (secs != date_secs or date_len == 0) {
            date_len = formatHttpDate(secs, &date_buf).len;
            date_secs = secs;
        }
    }

    return date_buf[0..date_len];
}

fn formatHttpDate(secs: u64, buf: []u8) []u8 {
    const ep = std.time.epoch;
    const es = ep.EpochSeconds{ .secs = secs };
    const epoch_day = es.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = es.getDaySeconds();
    const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const dow = (@as(u64, epoch_day.day) % 7 + 4) % 7;

    return std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        day_names[dow],
        @as(u32, month_day.day_index) + 1,
        month_names[@intFromEnum(month_day.month) - 1],
        year_day.year,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch buf[0..0];
}

/// Write one response (head then body) without letting a stalled client
/// block the worker: send non-blocking, park the remainder on a full
/// socket buffer, keep per-fd order by appending behind a parked response.
///
/// Note:
/// - a close-marked reply (tl_write_blocking) writes blocking instead, the
///   engine worker closes the fd the moment it returns.
fn deliver(fd: std.posix.fd_t, head: []const u8, body: []const u8) void {
    const pool = tl_pool orelse {
        deliverBlocking(fd, head, body, 0);
        return;
    };

    if (tl_write_blocking) {
        if (pool.pw_active > 0) {
            if (findPending(pool, fd)) |slot| flushSlotBlocking(pool, slot);
        }

        deliverBlocking(fd, head, body, 0);

        return;
    }

    if (pool.pw_active > 0) {
        if (findPending(pool, fd)) |slot| {
            if (slot.len + head.len + body.len <= slot.buf.len) {
                @memcpy(slot.buf[slot.len..][0..head.len], head);
                @memcpy(slot.buf[slot.len + head.len ..][0..body.len], body);
                slot.len += head.len + body.len;

                return;
            }

            flushSlotBlocking(pool, slot);
        }
    }

    const total = head.len + body.len;
    var sent: usize = 0;
    while (sent < total) {
        var iovs: [2]std.posix.iovec_const = undefined;
        var iov_count: usize = 0;
        if (sent < head.len) {
            iovs[0] = .{ .base = head[sent..].ptr, .len = head.len - sent };
            iovs[1] = .{ .base = body.ptr, .len = body.len };
            iov_count = 2;
        } else {
            iovs[0] = .{ .base = body[sent - head.len ..].ptr, .len = total - sent };
            iov_count = 1;
        }

        const msg = std.os.linux.msghdr_const{
            .name = null,
            .namelen = 0,
            .iov = &iovs,
            .iovlen = iov_count,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };
        const rc = std.os.linux.sendmsg(fd, &msg, std.os.linux.MSG.DONTWAIT | std.os.linux.MSG.NOSIGNAL);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const sent_now: usize = @intCast(rc);
                if (sent_now == 0) return;

                sent += sent_now;
            },
            .INTR => continue,
            .AGAIN => {
                park(pool, fd, head, body, sent);
                return;
            },
            else => return,
        }
    }
}

/// Blocking tail of a delivery, from `sent` bytes into head plus body.
fn deliverBlocking(fd: std.posix.fd_t, head: []const u8, body: []const u8, sent: usize) void {
    if (sent < head.len) {
        zix.Http1.writeAllFD(fd, head[sent..]) catch return;
        zix.Http1.writeAllFD(fd, body) catch {};

        return;
    }

    zix.Http1.writeAllFD(fd, body[sent - head.len ..]) catch {};
}

/// Park the unsent remainder of a response in the worker's pending pool. A
/// full pool finishes blocking instead (the pre-parking behavior).
fn park(pool: *WritePool, fd: std.posix.fd_t, head: []const u8, body: []const u8, sent: usize) void {
    const slot = allocPending(pool, fd) orelse {
        deliverBlocking(fd, head, body, sent);
        return;
    };

    var len: usize = 0;
    if (sent < head.len) {
        const head_rest = head[sent..];
        @memcpy(slot.buf[0..head_rest.len], head_rest);
        len = head_rest.len;
        @memcpy(slot.buf[len..][0..body.len], body);
        len += body.len;
    } else {
        const body_rest = body[sent - head.len ..];
        @memcpy(slot.buf[0..body_rest.len], body_rest);
        len = body_rest.len;
    }

    slot.sent = 0;
    slot.len = len;
    pool.pw_active += 1;
}

fn findPending(pool: *WritePool, fd: std.posix.fd_t) ?*PendingWrite {
    for (&pool.pw_slots) |*slot| {
        if (slot.len > 0 and slot.fd == fd) return slot;
    }

    return null;
}

fn allocPending(pool: *WritePool, fd: std.posix.fd_t) ?*PendingWrite {
    for (&pool.pw_slots) |*slot| {
        if (slot.len == 0) {
            slot.fd = fd;
            return slot;
        }
    }

    return null;
}

/// Drain one parked slot blocking (order guard before a same-fd write).
fn flushSlotBlocking(pool: *WritePool, slot: *PendingWrite) void {
    zix.Http1.writeAllFD(slot.fd, slot.buf[slot.sent..slot.len]) catch {};

    slot.len = 0;
    slot.sent = 0;
    pool.pw_active -= 1;
}

/// One non-blocking pass over the worker's parked responses.
///
/// Return:
/// - true when any parked bytes moved or a slot freed
fn flushPendingWrites(pool: *WritePool) bool {
    var progressed = false;

    var remaining = pool.pw_active;
    for (&pool.pw_slots) |*slot| {
        if (remaining == 0) break;
        if (slot.len == 0) continue;

        remaining -= 1;

        while (slot.sent < slot.len) {
            const rc = std.os.linux.sendto(slot.fd, slot.buf[slot.sent..].ptr, slot.len - slot.sent, std.os.linux.MSG.DONTWAIT | std.os.linux.MSG.NOSIGNAL, null, 0);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    const sent_now: usize = @intCast(rc);
                    if (sent_now == 0) break;

                    slot.sent += sent_now;
                    progressed = true;
                },
                .INTR => continue,
                .AGAIN => break,
                else => {
                    // client gone: drop the remainder
                    slot.sent = slot.len;
                    progressed = true;
                },
            }
        }

        if (slot.sent >= slot.len) {
            slot.len = 0;
            slot.sent = 0;
            pool.pw_active -= 1;
        }
    }

    return progressed;
}

fn sendJson(fd: std.posix.fd_t, body: []const u8) void {
    var head_buf: [HEAD_MAX]u8 = undefined;

    deliver(fd, buildHead(&head_buf, 200, "application/json", body.len), body);
}

fn sendStatus(fd: std.posix.fd_t, status: u16, body: []const u8) void {
    var head_buf: [HEAD_MAX]u8 = undefined;

    deliver(fd, buildHead(&head_buf, status, "application/json", body.len), body);
}

fn send503(fd: std.posix.fd_t) void {
    const body = "Service Unavailable";
    var head_buf: [HEAD_MAX]u8 = undefined;

    deliver(fd, buildHead(&head_buf, 503, "text/plain", body.len), body);
}

fn send404(fd: std.posix.fd_t) void {
    const body = "Not Found";
    var head_buf: [HEAD_MAX]u8 = undefined;

    deliver(fd, buildHead(&head_buf, 404, "text/plain", body.len), body);
}

/// 200 JSON response with the X-Cache header the crud cache check reads.
fn sendCrudBody(fd: std.posix.fd_t, body: []const u8, cache_state: []const u8) void {
    var hdr_buf: [128]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Cache: {s}\r\nContent-Length: {d}\r\n\r\n", .{ cache_state, body.len }) catch return;

    deliver(fd, hdr, body);
}

// --------------------------------------------------------- //

/// Read DATABASE_URL and DATABASE_MAX_CONN once at startup. Absent or
/// malformed DATABASE_URL leaves the DB endpoints answering 503.
pub fn init(process: std.process.Init) void {
    const url_text = process.environ_map.get("DATABASE_URL") orelse return;

    g_config = postgrez.parseUrl(url_text) catch return;
    g_config.tls = .OFF;
    g_config.dispatch_model = .URING;
    g_io = process.io;
    g_enabled = true;

    const cpu = std.Thread.getCpuCount() catch 8;

    if (process.environ_map.get("DATABASE_MAX_CONN")) |max_text| {
        if (std.fmt.parseInt(usize, max_text, 10)) |parsed| {
            if (parsed > 0) g_conns = parsed;
        } else |_| {}
    } else {
        g_conns = connsFor(cpu);
    }
}

/// Encode the prepared-statement bytes and mark the lanes ready to open.
/// Does nothing when DATABASE_URL was absent, so non-DB profiles touch
/// nothing.
pub fn start() void {
    if (!g_enabled) return;

    // Pre-encode one Parse plus Sync per named statement, handed to Line.open
    // so every connection prepares them before the pipelined loop runs.
    var fixed = std.heap.FixedBufferAllocator.init(&g_prepare_buf);
    const allocator = fixed.allocator();

    inline for (STATEMENTS, 0..) |spec, index| {
        var out: std.ArrayList(u8) = .empty;
        frontend.parse(allocator, &out, spec.name, spec.sql, &.{}) catch {
            g_enabled = false;
            return;
        };
        frontend.sync(allocator, &out) catch {
            g_enabled = false;
            return;
        };

        g_prepares[index] = out.items;
    }

    g_open = true;
}

// Engine-worker lanes: one Lane per worker, single-threaded (every field is
// touched only by the owning worker). The embedded pool supplies the
// pending-write slots the shared send helpers park into through tl_pool.
const LANE_LINES_MAX = 4;

const Lane = struct {
    pool: WritePool = .{},
    lines: [LANE_LINES_MAX]*postgrez.dispatch.Line = undefined,
    line_count: usize = 0,
    slots: [SLOT_CAP]Slot = undefined,
    slot_line: [SLOT_CAP]u8 = undefined,
    slot_live: [SLOT_CAP]bool = @splat(false),
    free: [SLOT_CAP]usize = undefined,
    free_count: usize = 0,
    queue: [SLOT_CAP]QueuedJob = undefined,
    q_head: usize = 0,
    q_tail: usize = 0,
    scan_inflight: usize = 0,
    scan_cap: usize = 0,
};

threadlocal var tl_lane: ?*Lane = null;

/// This worker's lane, opened lazily on its first DB request (blocking
/// connect + prepare warm-up, once per worker).
fn laneGet() ?*Lane {
    if (tl_lane) |lane| return lane;
    if (!g_open) return null;

    const lane = std.heap.smp_allocator.create(Lane) catch return null;
    lane.* = .{};

    const cpu = std.Thread.getCpuCount() catch 8;
    const want = std.math.clamp(g_conns / cpu, 1, LANE_LINES_MAX);

    var opened: usize = 0;
    while (opened < want) : (opened += 1) {
        lane.lines[opened] = postgrez.dispatch.Line.open(std.heap.smp_allocator, g_io, g_config, .{
            .conns = 1,
            .window = WINDOW,
            .context = lane,
            .on_reply = onLaneReply,
            .prepare = &g_prepares,
        }) catch break;
    }

    if (opened == 0) {
        std.heap.smp_allocator.destroy(lane);

        return null;
    }

    lane.line_count = opened;
    lane.scan_cap = opened * SCAN_CAP_PER_CONN;
    for (0..SLOT_CAP) |index| lane.free[index] = SLOT_CAP - 1 - index;
    lane.free_count = SLOT_CAP;

    tl_lane = lane;
    tl_pool = &lane.pool;

    zix.Http1.setExternalHandler(onLaneReadable);
    var armed = false;
    for (lane.lines[0..opened]) |line| {
        if (zix.Http1.uringWatchFd(line.fd())) armed = true;
    }

    if (!armed) {
        for (lane.lines[0..opened]) |line| line.deinit();
        std.heap.smp_allocator.destroy(lane);
        tl_lane = null;
        tl_pool = null;

        return null;
    }

    return lane;
}

fn laneQueueFull(lane: *const Lane) bool {
    return lane.q_tail -% lane.q_head >= SLOT_CAP;
}

fn lanePush(lane: *Lane, item: QueuedJob) void {
    lane.queue[lane.q_tail & (SLOT_CAP - 1)] = item;
    lane.q_tail +%= 1;
}

/// The least loaded line takes the next request.
fn laneLineFor(lane: *const Lane) usize {
    var best: usize = 0;
    for (lane.lines[1..lane.line_count], 1..) |line, index| {
        if (line.pending() < lane.lines[best].pending()) best = index;
    }

    return best;
}

/// Read replies from every line that owes some. A dead connection sheds
/// everything it owes and leaves the rotation.
fn lanePump(lane: *Lane) void {
    var index: usize = 0;
    while (index < lane.line_count) {
        const line = lane.lines[index];

        if (line.pending() > 0) {
            _ = line.pump() catch {
                laneDropLine(lane, index);
                continue;
            };
        }

        index += 1;
    }
}

/// Shed every request a dead connection owes (503) and drop it from the
/// rotation, so a lost backend degrades to shedding instead of hangs.
fn laneDropLine(lane: *Lane, index: usize) void {
    const line = lane.lines[index];

    for (0..SLOT_CAP) |slot_index| {
        if (!lane.slot_live[slot_index] or lane.slot_line[slot_index] != index) continue;

        const slot = lane.slots[slot_index];
        if (slot.job == .ASYNC_DB) lane.scan_inflight -= 1;
        shed(.{ .job = slot.job, .completion = slot.completion });
        lane.slot_live[slot_index] = false;
        lane.free[lane.free_count] = slot_index;
        lane.free_count += 1;
    }

    const last = lane.line_count - 1;
    lane.lines[index] = lane.lines[last];
    for (0..SLOT_CAP) |slot_index| {
        if (lane.slot_live[slot_index] and lane.slot_line[slot_index] == last) {
            lane.slot_line[slot_index] = @intCast(index);
        }
    }

    lane.line_count -= 1;
    line.deinit();
}

/// Drain queued jobs into the lines until a window fills, then flush any
/// parked client writes. Runs on the owning engine worker only.
fn laneDrain(lane: *Lane) void {
    while (lane.line_count > 0 and lane.q_head != lane.q_tail) {
        const item = lane.queue[lane.q_head & (SLOT_CAP - 1)];

        if (item.job == .ASYNC_DB and lane.scan_inflight >= lane.scan_cap) break;
        if (lane.free_count == 0) break;

        if (serveFromCache(item)) {
            lane.q_head +%= 1;
            continue;
        }

        lane.free_count -= 1;
        const tag = lane.free[lane.free_count];
        lane.slots[tag] = .{ .job = item.job, .completion = item.completion };

        const request = buildRequest(item.job) catch {
            lane.free_count += 1;
            lane.q_head +%= 1;
            shed(item);

            continue;
        };

        const line_index = laneLineFor(lane);
        if (!lane.lines[line_index].submit(request, tag)) {
            lane.free_count += 1;

            break;
        }

        lane.slot_line[tag] = @intCast(line_index);
        lane.slot_live[tag] = true;
        if (item.job == .ASYNC_DB) lane.scan_inflight += 1;
        lane.q_head +%= 1;
    }

    for (lane.lines[0..lane.line_count]) |line| line.flush();

    if (lane.pool.pw_active > 0) _ = flushPendingWrites(&lane.pool);
}

/// Reply sink for the lane: render and send, then release the slot.
fn onLaneReply(context: ?*anyopaque, tag: u64, reply: []const u8) void {
    const lane: *Lane = @ptrCast(@alignCast(context.?));

    const slot = &lane.slots[@intCast(tag)];
    const job = slot.job;
    const completion = slot.completion;

    tl_write_blocking = completion != null;
    defer tl_write_blocking = false;

    switch (job) {
        .ASYNC_DB => |request| renderRows(reply, request.fd, .ASYNC_DB, .{}),
        .CRUD_LIST => |request| renderRows(reply, request.fd, .CRUD_LIST, .{
            .page = request.page,
            .limit = request.limit,
            .category = request.category_buf[0..request.category_len],
        }),
        .CRUD_GET => |request| renderRows(reply, request.fd, .CRUD_GET, .{ .id = request.id }),
        .CRUD_CREATE => |request| finishWrite(reply, request.fd, request.id, .CREATE),
        .CRUD_UPDATE => |request| finishWrite(reply, request.fd, request.id, .UPDATE),
    }

    if (completion) |signal_ptr| signal_ptr.done.store(true, .release);

    if (job == .ASYNC_DB) lane.scan_inflight -= 1;
    lane.slot_live[@intCast(tag)] = false;
    lane.free[lane.free_count] = @intCast(tag);
    lane.free_count += 1;
}

/// Ring readable callback for a lane fd: pump and refill. The watch is
/// multishot, the engine keeps it armed.
fn onLaneReadable(fd: std.posix.fd_t) void {
    _ = fd;

    const lane = tl_lane orelse return;

    lanePump(lane);
    laneDrain(lane);
}

/// Lane-mode submit. For a close request the same thread owns the pump, so
/// waiting means pumping.
fn laneSubmit(job: Job, keep_alive: bool) bool {
    const lane = laneGet() orelse return false;
    if (lane.line_count == 0) return false;

    lanePump(lane);

    if (keep_alive) {
        if (laneQueueFull(lane)) return false;

        lanePush(lane, .{ .job = job });
        laneDrain(lane);

        return true;
    }

    var completion: Completion = .{};
    if (laneQueueFull(lane)) return false;

    lanePush(lane, .{ .job = job, .completion = &completion });
    laneDrain(lane);
    while (!completion.done.load(.acquire)) {
        lanePump(lane);
        laneDrain(lane);
    }

    return true;
}

/// Queue a Job on this worker's lane.
///
/// Note:
/// - keep_alive false marks a close request: the call pumps the lane until
///   the response is written (the engine closes the fd on return).
///
/// Return:
/// - true when the response is written or owned by the lane
/// - false when the lane is down or full (caller sheds 503)
pub fn submit(job: Job, keep_alive: bool) bool {
    return laneSubmit(job, keep_alive);
}

/// Queue a Job on this worker's lane. For a close request submit blocks
/// until the response is written, so a deferred write never races the fd
/// close.
pub fn submitJob(head: *const zix.Http1.ParsedHead, job: Job) bool {
    return submit(job, head.keep_alive);
}
