//! HttpArena entry for Anole (https://github.com/xuckless/anole), standard
//! mode: documented APIs and default settings.
//!
//! One process. On its own (the per-profile container) it serves HttpArena's
//! four ports:
//!
//!   8080 HTTP/1.1 + h2c (gRPC)   8081 TLS, HTTP/1.1 only
//!   8082 h2c only                8443 TLS h2 + HTTP/1.1, HTTP/3 on UDP 8443
//!
//! Behind a gateway edge (compose.*.yml set ANOLE_ROLE=gateway) it serves
//! cleartext HTTP/1.1 on 127.0.0.1:8085 only, for the edge's upstream pool;
//! the edge owns 8443 (and answers the harness's readiness probe on 8080).
const std = @import("std");
const anole = @import("anole");
const pb = @import("benchmark_pb");

pub const std_options = anole.std_options;

const Rating = struct { score: i64, count: i64 };

const Item = struct {
    id: i64,
    name: []const u8,
    category: []const u8,
    price: i64,
    quantity: i64,
    active: bool,
    tags: []const []const u8,
    rating: Rating,
};

const Priced = struct {
    id: i64,
    name: []const u8,
    category: []const u8,
    price: i64,
    quantity: i64,
    active: bool,
    tags: []const []const u8,
    rating: Rating,
    total: i64,
};

const App = struct {
    dataset: []const Item = &.{},
    /// Postgres (DATABASE_URL), for /async-db and the production-stack API.
    db: *anole.pg.Client = undefined,
    /// Redis (REDIS_URL), the production stack's shared cache.
    redis: *anole.redis.Client = undefined,
};

fn baseline(req: *anole.Request, res: *anole.Response) !void {
    var sum: i64 = (req.query.getInt(i64, "a") orelse 0) + (req.query.getInt(i64, "b") orelse 0);
    if (req.method == .post) {
        if (try req.body()) |body| sum += std.fmt.parseInt(i64, std.mem.trim(u8, body, " \t\r\n"), 10) catch 0;
    }
    try res.print(.text, "{d}", .{sum});
}

fn pipeline(_: *anole.Request, res: *anole.Response) !void {
    try res.print(.text, "ok", .{});
}

fn delay(req: *anole.Request, res: *anole.Response) !void {
    const ms = req.params.getInt(u32, "ms") orelse return res.fail(.bad_request, "bad delay");
    if (ms > 0) try req.io.sleep(.fromMilliseconds(ms), .awake);
    try res.print(.text, "{d}", .{ms});
}

/// /json/{count} (and /json: the gateway profiles' 50 items).
fn json(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const count = if (req.params.get("count") != null)
        req.params.getInt(usize, "count") orelse return res.fail(.bad_request, "bad count")
    else
        @min(50, app.dataset.len);
    if (count < 1 or count > app.dataset.len) return res.fail(.bad_request, "bad count");
    const m = req.query.getInt(i64, "m") orelse 1;
    const items = try res.arena.alloc(Priced, count);
    for (app.dataset[0..count], items) |it, *out| out.* = .{
        .id = it.id,
        .name = it.name,
        .category = it.category,
        .price = it.price,
        .quantity = it.quantity,
        .active = it.active,
        .tags = it.tags,
        .rating = it.rating,
        .total = it.price * it.quantity * m,
    };
    // Compressed when the client accepts it (gzip or zstd), as configured
    // per response in docs/routing.md#compression.
    res.compress = true;
    try res.json(.{ .items = items, .count = count });
}

fn echo(req: *anole.Request, res: *anole.Response) !void {
    res.body = (try req.body()) orelse "";
    try res.header("Content-Type", "application/octet-stream");
}

/// /async-db: a price range from the items table (no index on price).
const DbRow = struct {
    id: i64,
    name: []const u8,
    category: []const u8,
    price: i64,
    quantity: i64,
    active: bool,
    tags: std.json.Value,
    rating_score: i64,
    rating_count: i64,
};

const DbItem = struct {
    id: i64,
    name: []const u8,
    category: []const u8,
    price: i64,
    quantity: i64,
    active: bool,
    tags: std.json.Value,
    rating: Rating,
};

fn asyncDb(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const min = req.query.getInt(i64, "min") orelse 10;
    const max = req.query.getInt(i64, "max") orelse 50;
    const limit = std.math.clamp(req.query.getInt(i64, "limit") orelse 50, 1, 50);
    // No database (or none yet): the profile's empty answer, not an error.
    const rows = app.db.all(DbRow, req,
        \\SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count
        \\  FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3
    , .{ min, max, limit }) catch &.{};
    const items = try res.arena.alloc(DbItem, rows.len);
    for (rows, items) |r, *out| out.* = .{
        .id = r.id,
        .name = r.name,
        .category = r.category,
        .price = r.price,
        .quantity = r.quantity,
        .active = r.active,
        .tags = r.tags,
        .rating = .{ .score = r.rating_score, .count = r.rating_count },
    };
    try res.json(.{ .items = items, .count = items.len });
}

// Production stack: the edge verifies the JWT (the shared authsvc) and
// passes X-User-Id; reads are cache-aside, Anole's per-executor result
// cache (L1, docs/database.md#caching) in front of Redis (L2) in front of
// Postgres.

/// L1: kept per executor, at most 1 s for items and 30 s for users, as the
/// profile allows. A nil (L2 miss) is kept too, so a fill drops it.
const item_l1: anole.db.QueryOptions = .{ .cache = .{ .ttl = .fromSeconds(1), .tag = "items" } };
const user_l1: anole.db.QueryOptions = .{ .cache = .{ .ttl = .fromSeconds(30), .tag = "users" } };

const ApiItem = struct {
    id: i64,
    name: []const u8,
    category: []const u8,
    price: i64,
    quantity: i64,
    active: bool,
    rating: Rating,
};

const ItemRow = struct {
    id: i64,
    name: []const u8,
    category: []const u8,
    price: i64,
    quantity: i64,
    active: bool,
    rating_score: i64,
    rating_count: i64,
};

const User = struct { id: i64, name: []const u8, email: []const u8, plan: []const u8 };

/// GET /api/items/{id}: L1, then L2, then Postgres; X-Cache says which.
fn getItem(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const id = req.params.getInt(i64, "id") orelse return error.NotFound;
    const key = try std.fmt.allocPrint(req.arena, "item:{d}", .{id});
    if (try app.redis.with(item_l1).get(req, key)) |cached| {
        try res.header("X-Cache", "HIT");
        try res.header("Content-Type", "application/json");
        res.body = cached;
        return;
    }
    const row = try app.db.one(ItemRow, req,
        \\SELECT id, name, category, price, quantity, active, rating_score, rating_count
        \\  FROM items WHERE id = $1
    , .{id});
    const body = try std.json.Stringify.valueAlloc(req.arena, ApiItem{
        .id = row.id,
        .name = row.name,
        .category = row.category,
        .price = row.price,
        .quantity = row.quantity,
        .active = row.active,
        .rating = .{ .score = row.rating_score, .count = row.rating_count },
    }, .{});
    _ = try app.redis.set(req, key, body, .{ .ttl = .fromSeconds(1) });
    app.redis.cache.invalidateQuery("GET", .{key});
    try res.header("X-Cache", "MISS");
    try res.header("Content-Type", "application/json");
    res.body = body;
}

/// POST /api/items/{id}: update the row, then drop it from L2 and L1.
fn updateItem(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const id = req.params.getInt(i64, "id") orelse return error.NotFound;
    const in = try req.bind(struct { name: []const u8, price: i64, quantity: i64 });
    const changed = try app.db.exec(req, "UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4", .{ in.name, in.price, in.quantity, id });
    if (changed == 0) return error.NotFound;
    const key = try std.fmt.allocPrint(req.arena, "item:{d}", .{id});
    _ = try app.redis.del(req, key);
    app.redis.cache.invalidateQuery("GET", .{key});
    res.status = .no_content;
}

/// GET /api/me: the user the edge authenticated, cache-aside as items.
fn me(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const uid = std.fmt.parseInt(i64, req.headers.get("X-User-Id") orelse "", 10) catch return error.Unauthorized;
    const key = try std.fmt.allocPrint(req.arena, "user:{d}", .{uid});
    if (try app.redis.with(user_l1).get(req, key)) |cached| {
        try res.header("X-Cache", "HIT");
        try res.header("Content-Type", "application/json");
        res.body = cached;
        return;
    }
    const user = try app.db.one(User, req, "SELECT id, name, email, plan FROM users WHERE id = $1", .{uid});
    const body = try std.json.Stringify.valueAlloc(req.arena, user, .{});
    _ = try app.redis.set(req, key, body, .{ .ttl = .fromSeconds(30) });
    app.redis.cache.invalidateQuery("GET", .{key});
    try res.header("X-Cache", "MISS");
    try res.header("Content-Type", "application/json");
    res.body = body;
}

/// /ws: every text or binary message straight back.
const WsEcho = struct {
    pub fn message(ws: *anole.websocket.Socket, msg: anole.websocket.Message) !void {
        try ws.send(msg.type, msg.data);
    }
};

// gRPC: benchmark.BenchmarkService (requests/benchmark.proto).
const Call = anole.grpc.Call;

const Benchmark = struct {
    pub fn GetSum(_: *Call, req: pb.SumRequest) anyerror!pb.SumReply {
        return .{ .result = req.a +% req.b };
    }
    pub fn StreamSum(call: *Call, req: pb.StreamRequest, out: *std.Io.Queue(pb.SumReply)) anyerror!void {
        var i: i32 = 0;
        while (i < req.count) : (i += 1) try out.putOne(call.io, .{ .result = req.a +% req.b +% i });
    }
    pub fn CollectSum(call: *Call, in: *std.Io.Queue(pb.SumRequest)) anyerror!pb.SumReply {
        var total: i32 = 0;
        while (true) {
            const r = in.getOne(call.io) catch |err| switch (err) {
                error.Closed => return .{ .result = total },
                else => |e| return e,
            };
            total +%= r.a +% r.b;
        }
    }
    pub fn EchoSum(call: *Call, in: *std.Io.Queue(pb.SumRequest), out: *std.Io.Queue(pb.SumReply)) anyerror!void {
        while (true) {
            const r = in.getOne(call.io) catch |err| switch (err) {
                error.Closed => return,
                else => |e| return e,
            };
            try out.putOne(call.io, .{ .result = r.a +% r.b });
        }
    }
};

const cert: anole.Cert = .fromFiles("/certs/server.crt", "/certs/server.key");

/// HttpArena's ports, one process (docs/server.md#several-listeners).
const standalone: []const anole.ServerOptions.Listener = &.{
    .{ .name = "h1", .address = "0.0.0.0", .port = 8080 },
    .{ .name = "h1-tls", .address = "0.0.0.0", .port = 8081, .tls = .{ .cert = cert }, .http2 = false },
    .{ .name = "h2c", .address = "0.0.0.0", .port = 8082, .http1 = false },
    .{ .name = "tls", .address = "0.0.0.0", .port = 8443, .tls = .{ .cert = cert }, .http3 = true },
};

/// Behind a gateway edge: cleartext HTTP/1.1 on loopback for the edge.
const gateway: []const anole.ServerOptions.Listener = &.{
    .{ .name = "upstream", .address = "127.0.0.1", .port = 8085, .http2 = false },
};

pub fn main(init: std.process.Init) !void {
    const behind_edge = std.mem.eql(u8, init.environ_map.get("ANOLE_ROLE") orelse "", "gateway");

    var state: App = .{};
    const raw = try std.Io.Dir.cwd().readFileAlloc(init.io, "/data/dataset.json", init.arena.allocator(), .limited(16 << 20));
    state.dataset = try std.json.parseFromSliceLeaky([]const Item, init.arena.allocator(), raw, .{ .ignore_unknown_fields = true });

    var app = try anole.Server(App).init(init.gpa, .{
        .listeners = if (behind_edge) gateway else standalone,
        // HTTP/3's UDP sockets on the IPv6 wildcard, which takes IPv4 too:
        // the harness's QUIC client tries ::1 for localhost and, unlike its
        // TCP clients, does not fall back to 127.0.0.1.
        .http3 = if (behind_edge) null else .{ .address = "::" },
    }, &state);
    defer app.deinit();

    // Pool sized from DATABASE_MAX_CONN, as the profiles ask; neither
    // connects before a handler needs it.
    const max_conn = std.fmt.parseInt(u32, init.environ_map.get("DATABASE_MAX_CONN") orelse "", 10) catch 256;
    state.db = try app.postgres(.{ .max_connections = max_conn });
    state.redis = try app.redis(.{});

    app.get("/baseline11", anole.noWait(baseline));
    app.post("/baseline11", anole.noWait(baseline));
    app.get("/baseline2", anole.noWait(baseline));
    app.post("/baseline2", anole.noWait(baseline));
    app.get("/pipeline", anole.noWait(pipeline));
    app.get("/delay/:ms", delay);
    app.get("/json", anole.noWait(json));
    app.get("/json/:count", anole.noWait(json));
    app.post("/echo", echo);
    app.get("/async-db", asyncDb);
    app.wsCallbacks("/ws", WsEcho);
    // Behind an edge, the edge serves /static from its own mount.
    if (!behind_edge) try app.staticDir("/static", "/data/static", .{ .precompressed = &.{ .br, .gzip } });
    app.grpcWith(pb.BenchmarkService, Benchmark, .{ .no_wait = true });

    // Production stack.
    app.get("/public/baseline", anole.noWait(baseline));
    app.get("/public/json/:count", anole.noWait(json));
    app.get("/api/items/:id", getItem);
    app.post("/api/items/:id", updateItem);
    app.get("/api/me", me);

    try app.run();
}
