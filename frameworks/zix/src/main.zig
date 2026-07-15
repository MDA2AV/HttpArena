//! HttpArena: zix
//!
//! zix.Http1 (.URING), Router-only: every request goes through the engine's
//! parser and the comptime Router. json-tls rides config.tls_port (dual
//! listener, one worker fleet). async-db and crud run on the postgrez.Executor
//! (owned by dbpg.zig) over one shared pool, single-item crud reads serve
//! from the in-process cache (crudcache.zig), rediz mirrors write-behind.

const std = @import("std");
const zix = @import("zix");

const dataset = @import("dataset.zig");
const handler = @import("handler.zig");
const dbpg = @import("dbpg.zig");
const dbrd = @import("dbrd.zig");

// --------------------------------------------------------- //

const IP: []const u8 = "::";
const PORT: u16 = 8080;
const DISPATCH_MODEL: zix.Http1.DispatchModel = .URING;

const MAX_HEADERS: u8 = 8;
const WORKERS: usize = 0;

const SEND_DATE_HEADER: bool = false;
const RESPONSE_CACHE: bool = true;
const CACHE_MAX_ENTRIES: u32 = 64;
const CACHE_MAX_VALUE_BYTES: u32 = 32 * 1024;

const TLS_PORT: u16 = 8081;
const TLS_CERT_DEFAULT: []const u8 = "/etc/zix-tls/server.crt";
const TLS_KEY_DEFAULT: []const u8 = "/etc/zix-tls/server.key";

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/baseline11", .handler = handler.baseline },
    .{ .path = "/pipeline", .handler = handler.pipeline },
    .{ .path = "/upload", .handler = handler.upload },
    .{ .path = "/async-db", .handler = handler.asyncDb },
    .{ .path = "/json", .handler = handler.jsonResp, .kind = .PREFIX },
    .{ .path = "/static", .handler = handler.static, .kind = .PREFIX },
    .{ .path = "/crud/items", .handler = handler.crudItems, .kind = .PREFIX },
});

pub fn main(process: std.process.Init) !void {
    // DB endpoints: the executor spawns nothing when DATABASE_URL is absent,
    // so non-DB profiles run zero extra threads and the DB routes answer 503.
    dbpg.init(process);
    dbrd.init(process);
    dbpg.startExecutor(handler.runBatch);

    var allocator_dataset = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer allocator_dataset.deinit();

    var dataset_path_buf: [512]u8 = undefined;
    const data_dir = "/data";
    const dataset_path = try std.fmt.bufPrint(&dataset_path_buf, "{s}/dataset.json", .{data_dir});
    handler.g_dataset = try dataset.load(allocator_dataset.allocator(), dataset_path);
    handler.g_static_base = std.fmt.bufPrint(&handler.g_static_base_buf, "{s}/static/", .{data_dir}) catch "/data/static/";

    var allocator_tls = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer allocator_tls.deinit();

    // json-tls https side. A failed cert load leaves tls_ctx null and the
    // cleartext listener keeps serving.
    var tls_ctx: ?zix.Tls.Context = zix.Tls.Context.init(allocator_tls.allocator(), process.io, .{
        .cert_path = TLS_CERT_DEFAULT,
        .key_path = TLS_KEY_DEFAULT,
        .alpn = &.{.HTTP_1_1},
        .min_version = .TLS_1_3,
    }) catch null;

    // Dual listener: one server serves cleartext on PORT and https on
    // TLS_PORT from the same .URING worker fleet.
    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .tls = if (tls_ctx) |*tls| tls else null,
        .tls_port = TLS_PORT,
        .dispatch_model = DISPATCH_MODEL,
        .max_headers = MAX_HEADERS,
        .workers = WORKERS,
        .send_date_header = SEND_DATE_HEADER,
        .response_cache = RESPONSE_CACHE,
        .cache_max_entries = CACHE_MAX_ENTRIES,
        .cache_max_value_bytes = CACHE_MAX_VALUE_BYTES,
        .cache_ttl_ms = handler.CACHE_TTL_MS,
        .kernel_backlog = 16 * 1024,
        .max_recv_buf = 8 * 1024,
        .uring_send_buf_size = 16 * 1024,
        .uring_idle_pool_floor = 1 * 1024 / 4,
        .uring_idle_pool_ceiling = 1 * 1024,
        .process_queue_len = 8192,
    });
    defer server.deinit();

    try server.run();
}
