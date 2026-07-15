//! PostgreSQL for the DB endpoints: parses DATABASE_URL and
//! DATABASE_MAX_CONN, then owns the postgrez.Executor that runs every round
//! trip off the engine workers. The batching, pooling, and prepared-statement
//! caching all live in the driver (postgrez.Executor), this module only wires
//! it to the entry's Job type and the request routes.

const std = @import("std");
const zix = @import("zix");

const postgrez = zix.Driver.postgrez;

// --------------------------------------------------------- //

pub const NAME_MAX = 96;
pub const CATEGORY_MAX = 48;

/// One prepared SQL slot per distinct statement the entry runs. The enum
/// value indexes the executor's per-connection statement cache.
pub const StatementId = enum(usize) {
    ASYNC_DB,
    CRUD_LIST,
    CRUD_GET,
    CRUD_UPSERT,
    CRUD_UPDATE,
};

pub const STATEMENT_COUNT = 5;

/// Jobs one batch drains, matches the driver max_pending_replies default.
pub const BATCH_MAX = 16;

/// The cache slot for a StatementId, for Batch.statement.
pub fn slot(id: StatementId) usize {
    return @intFromEnum(id);
}

/// One parsed DB request. Strings are copied into fixed buffers, the engine's
/// receive buffer is reused the moment the handler returns.
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

/// The batching executor specialized to the entry's Job and statement set.
pub const DbExecutor = postgrez.Executor(Job, STATEMENT_COUNT);

// Set once in init before startExecutor, read-only afterwards.
var g_io: std.Io = undefined;
var g_config: postgrez.Config = undefined;
var g_enabled: bool = false;
var g_max_conn: usize = 0;
var g_executor: ?*DbExecutor = null;

/// Read DATABASE_URL and DATABASE_MAX_CONN once at startup. Absent or
/// malformed DATABASE_URL leaves the DB endpoints answering 503.
pub fn init(process: std.process.Init) void {
    const url_text = process.environ_map.get("DATABASE_URL") orelse return;

    g_config = postgrez.parseUrl(url_text) catch return;
    g_config.max_pending_replies = BATCH_MAX;
    g_io = process.io;
    g_enabled = true;

    if (process.environ_map.get("DATABASE_MAX_CONN")) |max_text| {
        g_max_conn = std.fmt.parseInt(usize, max_text, 10) catch 0;
    }
}

pub fn enabled() bool {
    return g_enabled;
}

/// Build the executor over the parsed config. Does nothing when DATABASE_URL
/// was absent, so non-DB profiles spawn no worker threads.
pub fn startExecutor(run_batch: *const fn (*DbExecutor.Batch, []const Job) void) void {
    if (!g_enabled) return;

    g_executor = DbExecutor.init(std.heap.smp_allocator, g_io, g_config, .{
        .run_batch = run_batch,
        .max_conn_hint = g_max_conn,
        .batch_max = BATCH_MAX,
    }) catch null;
}

/// Queue a job on the executor.
///
/// Return:
/// - true when queued (a worker owns the response)
/// - false when the executor is down or the queue is full (shed 503)
pub fn submit(job: Job) bool {
    const executor = g_executor orelse return false;

    return executor.submit(job);
}

/// Run a job synchronously on the calling thread (for a request whose
/// connection is about to close, where a deferred write would race the
/// close).
///
/// Return:
/// - true when the executor ran it, false when it is down
pub fn runInline(job: Job) bool {
    const executor = g_executor orelse return false;

    return executor.runInline(job);
}
