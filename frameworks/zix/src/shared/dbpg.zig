//! PostgreSQL for the DB endpoints (async-db, crud) over the driver-owned
//! multiplexed transport (postgrez.Transport, .URING), sharded: the active
//! shard count (scaled from the CPU budget at init) transport threads each
//! own their slice of the pipelined connections, so reply decode, render,
//! and the client write are not serialized on one thread. Jobs route to a
//! shard by fd (per-fd order). Handlers build a Job and call submitJob,
//! replies render and write from onReply on the shard thread.

const std = @import("std");
const zix = @import("zix");

const crudcache = @import("crudcache.zig");
const dbrd = @import("dbrd.zig");

const postgrez = zix.Driver.postgrez;
const frontend = postgrez.frontend;
const backend = postgrez.backend;
const row = postgrez.row;

// --------------------------------------------------------- //

pub const NAME_MAX = 96;
pub const CATEGORY_MAX = 48;

/// Widest result set: the crud list adds a count(*) OVER() column to the nine
/// item columns, so ten columns bound the row decode scratch.
const MAX_COLUMNS = 16;

/// Pipeline depth per connection, matches the driver transport default.
const WINDOW = postgrez.dispatch.DEFAULT_WINDOW;

/// Bytes one rendered DB body may reach before renderDbRow sheds it. A crud
/// list of 100 rows tops out near 21 KiB.
const DB_BODY_MAX = 32 * 1024;

/// Transport shard ceiling. Each shard runs its own thread and Transport,
/// splitting the configured connections. The active count comes from
/// shardCountFor at init.
const MAX_SHARDS = 16; // 0:2 1:8 2:16

/// In-flight ASYNC_DB scans one shard allows: shard connections times this.
/// Caps how many concurrent price-range scans can over-feed the server.
/// Swept on the isolate bench: 2 under-feeds (43.3K), 4 is the knee (47.1K),
/// 8 thrashes (45.9K, p99 up). Keep 4 while the scan stays sequential.
const SCAN_CAP_PER_CONN = 4;

// SQL: column order is fixed here, the renderers decode cells by position.
const SQL_ASYNC_DB = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3";
const SQL_CRUD_LIST = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count, count(*) OVER() AS total FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3";
const SQL_CRUD_GET = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE id = $1";
const SQL_CRUD_UPSERT = "INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) VALUES ($1, $2, $3, $4, $5, true, '[]', 0, 0) ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, price = EXCLUDED.price, quantity = EXCLUDED.quantity";
const SQL_CRUD_UPDATE = "UPDATE items SET name = $2, category = $3, price = $4, quantity = $5 WHERE id = $1";

// Named prepared statements, one per SQL. Created on every connection at open
// (Transport prepare warm-up), so per request only Bind plus Execute is sent.
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
/// engine closes the fd on return). The engine worker spins on done until
/// the shard thread has written the response.
const Completion = struct {
    done: std.atomic.Value(bool) = .init(false),
};

/// One queued Job plus its optional close-marked completion signal.
const QueuedJob = struct {
    job: Job,
    completion: ?*Completion = null,
};

// --------------------------------------------------------- //

/// Jobs one shard queue holds (engine workers enqueue, the shard drains).
/// Per shard: at the two-shard floor this matches the single 8192 queue the
/// unsharded entry ran, more shards raise the fleet total.
const QUEUE_CAP = 4096;

/// In-flight Jobs one shard tracks, above its conns times WINDOW ceiling.
const SLOT_CAP = 1024;

/// Over-cap ASYNC_DB scans one shard can hold before shedding.
const SCAN_HOLD_CAP = 2048;

/// Client fds one shard can have parked mid-response at once.
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

/// One transport shard. Everything except the queue is touched only by the
/// shard's own thread, the queue spinlock serializes the engine workers.
const Shard = struct {
    transport: ?*postgrez.Transport = null,
    conns: usize = 0,

    q_buf: [QUEUE_CAP]QueuedJob = undefined,
    q_head: usize = 0,
    q_tail: usize = 0,
    q_lock: std.atomic.Value(bool) = .init(false),

    s_slots: [SLOT_CAP]Slot = undefined,
    s_free: [SLOT_CAP]usize = undefined,
    s_free_count: usize = 0,

    scan_cap: usize = 0,
    scan_inflight: usize = 0,
    scan_buf: [SCAN_HOLD_CAP]QueuedJob = undefined,
    scan_head: usize = 0,
    scan_tail: usize = 0,

    pw_slots: [PENDING_CAP]PendingWrite = @splat(.{}),
    pw_active: usize = 0,

    fn lock(self: *Shard) void {
        while (self.q_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Shard) void {
        self.q_lock.store(false, .release);
    }

    fn enqueue(self: *Shard, item: QueuedJob) bool {
        self.lock();
        defer self.unlock();

        if (self.q_tail -% self.q_head >= QUEUE_CAP) return false;

        self.q_buf[self.q_tail & (QUEUE_CAP - 1)] = item;
        self.q_tail +%= 1;

        return true;
    }

    fn dequeue(self: *Shard) ?QueuedJob {
        self.lock();
        defer self.unlock();

        if (self.q_head == self.q_tail) return null;

        const item = self.q_buf[self.q_head & (QUEUE_CAP - 1)];
        self.q_head +%= 1;

        return item;
    }

    fn slotInit(self: *Shard) void {
        for (0..SLOT_CAP) |index| self.s_free[index] = SLOT_CAP - 1 - index;

        self.s_free_count = SLOT_CAP;
    }

    fn slotAlloc(self: *Shard, item: QueuedJob) ?u64 {
        if (self.s_free_count == 0) return null;

        self.s_free_count -= 1;
        const index = self.s_free[self.s_free_count];
        self.s_slots[index] = .{ .job = item.job, .completion = item.completion };

        return index;
    }

    fn slotFree(self: *Shard, tag: u64) void {
        self.s_free[self.s_free_count] = @intCast(tag);
        self.s_free_count += 1;
    }

    /// Take a held scan once an in-flight scan slot is open.
    fn scanTake(self: *Shard) ?QueuedJob {
        if (self.scan_inflight >= self.scan_cap) return null;
        if (self.scan_head == self.scan_tail) return null;

        const item = self.scan_buf[self.scan_head & (SCAN_HOLD_CAP - 1)];
        self.scan_head +%= 1;

        return item;
    }

    /// Hold a scan that is over the in-flight cap, false when the ring is full.
    fn scanHold(self: *Shard, item: QueuedJob) bool {
        if (self.scan_tail -% self.scan_head >= SCAN_HOLD_CAP) return false;

        self.scan_buf[self.scan_tail & (SCAN_HOLD_CAP - 1)] = item;
        self.scan_tail +%= 1;

        return true;
    }
};

// --------------------------------------------------------- //

// Set once in init before start, read-only afterwards.
var g_io: std.Io = undefined;
var g_config: postgrez.Config = undefined;
var g_enabled: bool = false;
var g_conns: usize = 8;
var g_shard_count: usize = 2;

var g_shards: [MAX_SHARDS]Shard = @splat(.{});
var g_open: bool = false;
var g_running: std.atomic.Value(bool) = .init(false);

/// The shard owned by the current thread, set at transportLoop entry so the
/// send helpers under onReply reach the pending pool without threading a
/// parameter through every renderer.
threadlocal var tl_shard: ?*Shard = null;

/// Set around a close-marked reply: its delivery must block until fully
/// written because the engine worker closes the fd the moment it returns.
threadlocal var tl_write_blocking: bool = false;

fn shardOf(fd: std.posix.fd_t) *Shard {
    const key: usize = @intCast(fd);

    return &g_shards[key % g_shard_count];
}

/// Active transport shards for a CPU budget: one per four CPUs, floored at
/// the sharded baseline of two, capped at MAX_SHARDS.
fn shardCountFor(cpu: usize) usize {
    return std.math.clamp(cpu / 4, 2, MAX_SHARDS); // 0:2 1:clamp(cpu / 4, 2, 8)
}

/// Total DB connections for a CPU budget when DATABASE_MAX_CONN is absent.
/// The arena postgres runs max_connections=256, 64 stays well inside it.
fn connsFor(cpu: usize) usize {
    return std.math.clamp(cpu, 4, 64); // 0:clamp(cpu, 4, 16) 1:clamp(cpu, 4, 64)
}

/// One shard's slice of the conn budget: an even split, the first
/// total mod count shards take the remainder, never below one.
fn shardConns(total: usize, count: usize, index: usize) usize {
    return @max(1, total / count + @intFromBool(index < total % count));
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
    g_shard_count = shardCountFor(cpu);

    if (process.environ_map.get("DATABASE_MAX_CONN")) |max_text| {
        if (std.fmt.parseInt(usize, max_text, 10)) |parsed| {
            if (parsed > 0) g_conns = parsed;
        } else |_| {}
    } else {
        g_conns = connsFor(cpu);
    }
}

pub fn enabled() bool {
    return g_enabled;
}

/// Open one multiplexed transport per shard and spawn its poll-loop thread,
/// splitting the configured connections. Does nothing when DATABASE_URL was
/// absent, so non-DB profiles spawn no extra threads.
pub fn start() void {
    if (!g_enabled) return;

    // Pre-encode one Parse plus Sync per named statement, handed to open so the
    // transport parses each on every connection before the pipelined loop runs.
    var prepare_buf: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&prepare_buf);
    const allocator = fixed.allocator();

    var prepares: [STATEMENTS.len][]const u8 = undefined;
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

        prepares[index] = out.items;
    }

    g_running.store(true, .release);

    var opened: usize = 0;
    for (g_shards[0..g_shard_count], 0..) |*shard, index| {
        shard.conns = shardConns(g_conns, g_shard_count, index);
        shard.scan_cap = shard.conns * SCAN_CAP_PER_CONN;
        shard.slotInit();

        shard.transport = postgrez.Transport.open(std.heap.smp_allocator, g_io, g_config, .{
            .model = .URING,
            .conns = shard.conns,
            .window = WINDOW,
            .context = shard,
            .on_reply = onReply,
            .prepare = &prepares,
        }) catch break;

        const thread = std.Thread.spawn(.{}, transportLoop, .{shard}) catch break;
        thread.detach();

        opened += 1;
    }

    if (opened < g_shard_count) {
        g_enabled = false;
        g_running.store(false, .release);

        return;
    }

    g_open = true;
}

/// Queue a Job on its fd's shard thread.
///
/// Note:
/// - keep_alive false marks a close request: this blocks until the shard
///   thread writes the response (the engine closes the fd on return).
///
/// Return:
/// - true when the response is owned by the shard thread (or already written)
/// - false when the transport is down or the queue is full (shed 503)
pub fn submit(job: Job, keep_alive: bool) bool {
    if (!g_open) return false;

    const shard = shardOf(jobFd(job));
    if (keep_alive) return shard.enqueue(.{ .job = job });

    var completion: Completion = .{};
    if (!shard.enqueue(.{ .job = job, .completion = &completion })) return false;

    while (!completion.done.load(.acquire)) std.atomic.spinLoopHint();

    return true;
}

/// Queue a Job on its fd's shard thread. For a close request dbpg.submit blocks
/// until the response is written, so a deferred write never races the fd close.
pub fn submitJob(head: *const zix.Http1.ParsedHead, job: Job) bool {
    return submit(job, head.keep_alive);
}

// --------------------------------------------------------- //

/// One shard's thread: drain queued Jobs into the transport, poll for
/// replies, then flush parked client writes. A held-over Job retries before
/// the next dequeue, a held scan re-enters first once a scan slot frees.
fn transportLoop(shard: *Shard) void {
    tl_shard = shard;

    const transport = shard.transport.?;

    var holdover: ?QueuedJob = null;

    while (g_running.load(.acquire)) {
        var progressed = false;

        while (shard.s_free_count > 0) {
            const item = holdover orelse shard.scanTake() orelse shard.dequeue() orelse break;
            holdover = null;

            if (item.job == .ASYNC_DB and shard.scan_inflight >= shard.scan_cap) {
                if (!shard.scanHold(item)) shed(item);
                progressed = true;
                continue;
            }

            if (serveFromCache(item)) {
                progressed = true;
                continue;
            }

            const tag = shard.slotAlloc(item) orelse {
                holdover = item;
                break;
            };

            const request = buildRequest(item.job) catch {
                shard.slotFree(tag);
                shed(item);
                progressed = true;
                continue;
            };

            if (!transport.submit(request, tag)) {
                shard.slotFree(tag);
                holdover = item;
                break;
            }

            if (item.job == .ASYNC_DB) shard.scan_inflight += 1;
            progressed = true;
        }

        if (transport.pending() > 0) {
            _ = transport.poll() catch {};
            progressed = true;
        }

        if (shard.pw_active > 0 and flushPendingWrites(shard)) progressed = true;

        if (!progressed) idle();
    }
}

/// Brief park when nothing is queued and nothing is in flight, so the loop
/// does not busy-spin at idle. Under load the poll above always has work, so
/// this never runs.
fn idle() void {
    const req = std.os.linux.timespec{ .sec = 0, .nsec = 200 * std.time.ns_per_us };

    _ = std.os.linux.nanosleep(&req, null);
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
        .CRUD_LIST => |request| {
            const category = request.category_buf[0..request.category_len];
            const key = crudcache.listKey(category, request.page, request.limit);
            if (crudcache.listGetFresh(key, &db_body_buf)) |len| {
                sendJson(request.fd, db_body_buf[0..len]);
                signal(item);

                return true;
            }
        },
        else => {},
    }

    return false;
}

/// Shed a Job the transport could not accept: 503 the fd and release any
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

// --------------------------------------------------------- //

// Per shard-thread scratch. One reply is decoded at a time on each shard
// thread, so a per-thread buffer set is safe.
threadlocal var db_body_buf: [DB_BODY_MAX]u8 = undefined;
threadlocal var request_buf: [8 * 1024]u8 = undefined;
threadlocal var param_scratch: [8][24]u8 = undefined;

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
/// The returned slice lives in request_buf, consumed by transport.submit.
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

/// Reply sink, fired by the shard's transport once per completed request in
/// submit order. Decodes the backend messages, renders the response, writes
/// it to the fd, then releases the slot (and the scan slot for ASYNC_DB).
fn onReply(context: ?*anyopaque, tag: u64, reply: []const u8) void {
    const shard: *Shard = @ptrCast(@alignCast(context.?));

    const slot = &shard.s_slots[@intCast(tag)];
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

    if (job == .ASYNC_DB) shard.scan_inflight -= 1;
    shard.slotFree(tag);
}

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
    var total: i64 = 0;

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
                if (shape == .CRUD_LIST and count > 9) {
                    total = cellInt(columns[0..column_count], cells[0..count], 9) catch total;
                }
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
        pos = appendI64(&db_body_buf, pos, total);
        pos = appendStr(&db_body_buf, pos, ",\"page\":");
        pos = appendI64(&db_body_buf, pos, meta.page);
    } else {
        pos = appendStr(&db_body_buf, pos, "\"count\":");
        pos = appendInt(&db_body_buf, pos, rows);
    }
    db_body_buf[pos] = '}';
    pos += 1;

    if (shape == .CRUD_LIST) {
        const key = crudcache.listKey(meta.category, meta.page, meta.limit);
        crudcache.listPut(key, db_body_buf[0..pos]);
    }

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

/// MISS response plus the two cache fills: the in-process slot and the
/// write-behind Redis mirror.
fn finishCrudGet(id: i64, body: []const u8, fd: std.posix.fd_t) void {
    crudcache.put(id, body);
    dbrd.mirrorSet(id, body);

    sendCrudBody(fd, body, "MISS");
}

/// Drop the cached crud body on every write: the in-process slot first (the
/// read path), the Redis mirror write-behind.
fn invalidateCrud(id: i64) void {
    crudcache.remove(id);
    dbrd.mirrorDel(id);
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

/// Status lines for the transport-side responses, byte-matching the engine.
fn statusLine(status: u16) []const u8 {
    return switch (status) {
        200 => "HTTP/1.1 200 OK\r\n",
        201 => "HTTP/1.1 201 Created\r\n",
        404 => "HTTP/1.1 404 Not Found\r\n",
        503 => "HTTP/1.1 503 Service Unavailable\r\n",
        else => "HTTP/1.1 500 Internal Server Error\r\n",
    };
}

/// Build a response head byte-matching what the engine fd writers emit on a
/// shard thread (Content-Type, Content-Length, Date).
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

// --------------------------------------------------------- //

/// Write one response (head then body) without letting a stalled client
/// block the shard thread: send non-blocking, park the remainder on a full
/// socket buffer, keep per-fd order by appending behind a parked response.
///
/// Note:
/// - a close-marked reply (tl_write_blocking) writes blocking instead, the
///   engine worker closes the fd the moment it returns.
fn deliver(fd: std.posix.fd_t, head: []const u8, body: []const u8) void {
    const shard = tl_shard orelse {
        deliverBlocking(fd, head, body, 0);
        return;
    };

    if (tl_write_blocking) {
        if (shard.pw_active > 0) {
            if (findPending(shard, fd)) |slot| flushSlotBlocking(shard, slot);
        }

        deliverBlocking(fd, head, body, 0);

        return;
    }

    if (shard.pw_active > 0) {
        if (findPending(shard, fd)) |slot| {
            if (slot.len + head.len + body.len <= slot.buf.len) {
                @memcpy(slot.buf[slot.len..][0..head.len], head);
                @memcpy(slot.buf[slot.len + head.len ..][0..body.len], body);
                slot.len += head.len + body.len;

                return;
            }

            flushSlotBlocking(shard, slot);
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
                park(shard, fd, head, body, sent);
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

/// Park the unsent remainder of a response in the shard's pending pool. A
/// full pool finishes blocking instead (the pre-parking behavior).
fn park(shard: *Shard, fd: std.posix.fd_t, head: []const u8, body: []const u8, sent: usize) void {
    const slot = allocPending(shard, fd) orelse {
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
    shard.pw_active += 1;
}

fn findPending(shard: *Shard, fd: std.posix.fd_t) ?*PendingWrite {
    for (&shard.pw_slots) |*slot| {
        if (slot.len > 0 and slot.fd == fd) return slot;
    }

    return null;
}

fn allocPending(shard: *Shard, fd: std.posix.fd_t) ?*PendingWrite {
    for (&shard.pw_slots) |*slot| {
        if (slot.len == 0) {
            slot.fd = fd;
            return slot;
        }
    }

    return null;
}

/// Drain one parked slot blocking (order guard before a same-fd write).
fn flushSlotBlocking(shard: *Shard, slot: *PendingWrite) void {
    zix.Http1.writeAllFD(slot.fd, slot.buf[slot.sent..slot.len]) catch {};

    slot.len = 0;
    slot.sent = 0;
    shard.pw_active -= 1;
}

/// One non-blocking pass over the shard's parked responses.
///
/// Return:
/// - true when any parked bytes moved or a slot freed
fn flushPendingWrites(shard: *Shard) bool {
    var progressed = false;

    var remaining = shard.pw_active;
    for (&shard.pw_slots) |*slot| {
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
            shard.pw_active -= 1;
        }
    }

    return progressed;
}

// --------------------------------------------------------- //

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
// --------------------------------------------------------- //

test "3e test: buildHead matches the engine header shape" {
    var buf: [HEAD_MAX]u8 = undefined;
    const head = buildHead(&buf, 200, "application/json", 5);

    try std.testing.expect(std.mem.startsWith(u8, head, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 5\r\nDate: "));
    try std.testing.expect(std.mem.endsWith(u8, head, " GMT\r\n\r\n"));
}

test "3e test: scan hold ring admits under cap and holds at cap" {
    const shard = try std.testing.allocator.create(Shard);
    defer std.testing.allocator.destroy(shard);

    shard.* = .{};
    shard.scan_cap = 2;

    const job: Job = .{ .ASYNC_DB = .{ .fd = 0, .min = 1, .max = 2, .limit = 3 } };

    try std.testing.expect(shard.scanTake() == null);
    try std.testing.expect(shard.scanHold(.{ .job = job }));
    try std.testing.expect(shard.scanTake() != null);

    shard.scan_inflight = 2;
    try std.testing.expect(shard.scanHold(.{ .job = job }));
    try std.testing.expect(shard.scanTake() == null);

    shard.scan_inflight = 1;
    try std.testing.expect(shard.scanTake() != null);
}

test "shardCountFor scales with the cpu budget inside the clamp" {
    try std.testing.expectEqual(@as(usize, 2), shardCountFor(1));
    try std.testing.expectEqual(@as(usize, 2), shardCountFor(6));
    try std.testing.expectEqual(@as(usize, 4), shardCountFor(16));
    try std.testing.expectEqual(@as(usize, 8), shardCountFor(64));
    try std.testing.expectEqual(@as(usize, 8), shardCountFor(128));
}

test "connsFor scales with the cpu budget inside the clamp" {
    try std.testing.expectEqual(@as(usize, 4), connsFor(2));
    try std.testing.expectEqual(@as(usize, 6), connsFor(6));
    try std.testing.expectEqual(@as(usize, 16), connsFor(16));
    try std.testing.expectEqual(@as(usize, 64), connsFor(64));
    try std.testing.expectEqual(@as(usize, 64), connsFor(128));
}

test "shardConns splits the conn budget without loss" {
    var sum: usize = 0;
    for (0..8) |index| sum += shardConns(64, 8, index);
    try std.testing.expectEqual(@as(usize, 64), sum);

    sum = 0;
    for (0..2) |index| sum += shardConns(7, 2, index);
    try std.testing.expectEqual(@as(usize, 7), sum);
    try std.testing.expectEqual(@as(usize, 4), shardConns(7, 2, 0));
    try std.testing.expectEqual(@as(usize, 3), shardConns(7, 2, 1));

    // A budget smaller than the shard count still gives every shard one conn.
    try std.testing.expectEqual(@as(usize, 1), shardConns(1, 2, 1));
}

test "3e test: deliver parks on a full socket and flush completes it" {
    const linux = std.os.linux;

    const shard = try std.testing.allocator.create(Shard);
    defer std.testing.allocator.destroy(shard);

    shard.* = .{};
    tl_shard = shard;
    defer tl_shard = null;

    var fds: [2]i32 = undefined;
    try std.testing.expect(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds) == 0);
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);

    // Shrink the send buffer so the body cannot fit in one non-blocking send.
    const sndbuf: u32 = 4096;
    _ = linux.setsockopt(fds[0], linux.SOL.SOCKET, linux.SO.SNDBUF, @ptrCast(&sndbuf), @sizeOf(u32));

    const body = try std.testing.allocator.alloc(u8, DB_BODY_MAX);
    defer std.testing.allocator.free(body);

    @memset(body, 'x');

    var head_buf: [HEAD_MAX]u8 = undefined;
    const head = buildHead(&head_buf, 200, "application/json", body.len);
    const total = head.len + body.len;

    deliver(fds[0], head, body);

    try std.testing.expect(shard.pw_active == 1);

    // Drain the peer while flushing until the parked remainder is gone.
    var received: usize = 0;
    var recv_buf: [8192]u8 = undefined;
    var rounds: usize = 0;
    while (received < total) : (rounds += 1) {
        try std.testing.expect(rounds < 100_000);

        const rc = linux.recvfrom(fds[1], &recv_buf, recv_buf.len, linux.MSG.DONTWAIT, null, null);
        switch (std.posix.errno(rc)) {
            .SUCCESS => received += @intCast(rc),
            .AGAIN => {},
            else => return error.RecvFailed,
        }

        _ = flushPendingWrites(shard);
    }

    try std.testing.expect(shard.pw_active == 0);
    try std.testing.expect(received == total);
    try std.testing.expect(recv_buf[0] == 'x');
}
