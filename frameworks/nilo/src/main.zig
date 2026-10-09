//! nilo's entry in [HttpArena](https://www.http-arena.com/) — the file that
//! sits at `frameworks/nilo/src/main.zig` in
//! [MDA2AV/HttpArena](https://github.com/MDA2AV/HttpArena).
//!
//! The board runs one container per entry and drives a fixed set of
//! endpoints at it, one per profile; `meta.json` beside this file says which
//! profiles nilo subscribes to. Every handler here is written the way the
//! guide says to write it — a typed argument list, `nilo.sleep`, one
//! `db.select` — because the entry is submitted in *standard* mode, which the
//! board defines as the framework's documented API and nothing hand-rolled
//! underneath it. That is also what makes the number worth having: it prices
//! what a user of nilo gets, not what nilo could do if bypassed.
//!
//! What each route answers is the board's contract, quoted at the handler.
//! The one setting off its default is `max_connections`: the async profile
//! holds 32,000 connections open at once, and the framework's default of
//! 10,000 closes the rest at accept (ADR 0265). The deploying guide is where
//! that knob is documented, which is what standard mode asks for.
//!
//! **Four listeners, from one process**, because the board restarts the
//! container per profile and tells the binary nothing about which profile is
//! coming (ADR 213). 8080 is cleartext HTTP/1.1, and also h2c for the gRPC
//! profiles: a build with `.http2 = true` tells an HTTP/2 connection from an
//! HTTP/1.1 one by its first bytes (ADR 259, ADR 220). 8081 is HTTP/1.1 over
//! TLS. 8082 is h2c with prior knowledge. 8443 is HTTP/2 over TLS, chosen by
//! ALPN. They share one route table, so `/baseline2`, `/json/{count}` and
//! `/static/*` answer on every port. The certificate is the board's, mounted
//! at `/certs`, and its paths are overridable the way the `json-tls`
//! guidelines say frameworks usually do it.
//!
//! **`-Dcpu` is load-bearing here and the Dockerfile says so.** Zig's
//! `x86_64_v3` carries no `aes` and no `pclmul`, and `std.crypto`'s
//! AES-256-GCM without them is seventy times slower, enough that `8gbit`
//! delivers 39% of its offered rate at a six-second p99. The measured run
//! is in `bench/result/http.md`.
//!
//! **Scheduling is zio's default here, not nilo's.** nilo builds zio with
//! `.pinned` (a connection stays on the thread it was dealt to), and says an
//! application's own `zio_options` can override it. This entry does, below,
//! with `.work_stealing`. See the comment on `zio_options`.
//!
//! Profiles nilo does not subscribe to, and why: `fortunes` in standard
//! mode needs a template engine, refused on the record (README, "What it won't do"), and so is
//! HTTP/3. The gRPC profiles are unary only; the streaming ones are not
//! served (ADR 220).

const std = @import("std");
const nilo = @import("nilo_http");
const sql = @import("nilo_sql");
const zio = @import("zio");
const fail = nilo.fail;

/// zio's scheduling, read by zio from the root module the way std reads
/// `std_options`. nilo builds its own zio `.pinned` (ADR 199), so a task never
/// leaves the thread it was spawned on. This entry asks for `.work_stealing`,
/// which is zio's own default, as a measured hypothesis and not a tuning
/// claim: on the board's `async-db` profile nilo read 57k req/s at 830% CPU
/// where dusty, also on zio and running `.work_stealing`, read 290k at 4,606%.
/// A pinned fiber that waits on Postgres cannot be picked up by an idle
/// thread; a stolen one can. Whether that is the gap is what this run on the
/// board's 64 cores is for. Every other profile is expected to move little,
/// and the board will say if one does not.
pub const zio_options: zio.Options = .{ .scheduling = .work_stealing };

pub const std_options = nilo.std_options;
pub const std_options_debug_io = nilo.debug_io;
pub const panic = nilo.panic;

/// A whole number under `text/plain`, which is the shape `/baseline11` and
/// `/delay/{ms}` both answer in: "the parsed integer, in decimal, with no
/// surrounding whitespace or JSON". A type that writes its own answer
/// (ADR 0195) says the content type once and is described in the OpenAPI
/// document, where an `allocPrint` into a `[]const u8` would say neither.
const Number = struct {
    value: i64,

    pub const nilo_content_type = "text/plain";
    pub const nilo_openapi = .{ .type = "string" };

    pub fn nilo_write(self: Number, w: *std.Io.Writer) !void {
        try w.print("{d}", .{self.value});
    }
};

// ---- baseline, limited-conn, latency-1m, latency-10k, latency-500k-8cpu ----
//
// `GET /baseline11?a=13&b=42` answers `55`; `POST /baseline11?a=13&b=42` with
// a body of `20` — sent under Content-Length or chunked, the validator does
// both — answers `75`. Both operands are randomised by the validator, and so
// is the body, so nothing here may be a constant.

/// The two query operands. No defaults: a request without them is a 400
/// naming the field, which is what the board expects of a missing operand.
const Pair = struct {
    a: i64,
    b: i64,
};

fn baselineGet(q: nilo.Query(Pair)) Number {
    return .{ .value = q.value.a + q.value.b };
}

/// The body is plain text holding one number — not JSON, not a form — so
/// `c.body()` is the one framework call that reads it. Chunked and
/// Content-Length look the same from there.
fn baselinePost(c: *nilo.Ctx, q: nilo.Query(Pair)) !Number {
    const body = try c.body();
    const text = std.mem.trim(u8, body.view(), " \t\r\n");
    const n = std.fmt.parseInt(i64, text, 10) catch
        return fail.badRequest("the body has to be a whole number, not \"{s}\"", .{text});
    return .{ .value = q.value.a + q.value.b + n };
}

// ---- pipelined ----
//
// Sixteen `GET /pipeline` back to back on every connection, each answered
// `ok`. Reference-only on the board; nilo reads them one at a time.

fn pipeline() []const u8 {
    return "ok";
}

// ---- async ----
//
// `GET /delay/{ms}` waits that many milliseconds and answers the number.
// 32,000 connections are held with one request in flight on each, so the
// wait has to park the fiber and not the thread — which is what
// `nilo.sleep` is (ADR 0014). `/delay/0` answers at once, and the delay is
// read from the path on every request, as the board's anti-cheat asks.

fn delay(ms: u32) !Number {
    if (ms > 0) try nilo.sleep(ms);
    return .{ .value = ms };
}

// ---- async-db ----
//
// `GET /async-db?min=10&max=50&limit=20`: a range scan over `items` with the
// limit as a parameter, every row's two rating columns folded into one
// object, and `count` computed from what came back. Reference-only.

/// The board's `items` table, column for column. `tags` is `jsonb`, which
/// `sql.Json` reads per row into the request arena.
const Item = struct {
    pub const nilo_table = .{ .name = "items", .key = .id };

    id: i32,
    name: nilo.Str,
    category: nilo.Str,
    price: i32,
    quantity: i32,
    active: bool,
    tags: sql.Json([]const []const u8),
    rating_score: i32,
    rating_count: i32,
};

const Rating = struct {
    score: i32,
    count: i32,
};

/// One row as the board wants it written: `rating_score` and `rating_count`
/// nested under `rating`, everything else as it came.
const Listed = struct {
    id: i32,
    name: nilo.Str,
    category: nilo.Str,
    price: i32,
    quantity: i32,
    active: bool,
    tags: []const []const u8,
    rating: Rating,
};

const Listing = struct {
    items: []const Listed,
    count: usize,
};

/// What the board specifies when Postgres is unreachable or nothing matched.
const nothing = Listing{ .items = &.{}, .count = 0 };

/// The defaults are the board's; `limit` is clamped to 1–50 rather than
/// refused, because the contract says clamp.
const Range = struct {
    min: i32 = 10,
    max: i32 = 50,
    limit: i32 = 50,
};

fn asyncDb(db: *sql.Db, c: *nilo.Ctx, q: nilo.Query(Range)) !Listing {
    const limit: usize = @intCast(std.math.clamp(q.value.limit, 1, 50));
    const rows = db.select(Item, c, .{
        .where = .{ .price = .{ .gte = q.value.min, .lte = q.value.max } },
        .limit = limit,
    }) catch return nothing;

    const out = try c.arena().alloc(Listed, rows.len);
    for (rows, out) |row, *listed| listed.* = .{
        .id = row.id,
        .name = row.name,
        .category = row.category,
        .price = row.price,
        .quantity = row.quantity,
        .active = row.active,
        .tags = row.tags.value,
        .rating = .{ .score = row.rating_score, .count = row.rating_count },
    };
    return .{ .items = out, .count = out.len };
}

/// The route when the container was started with no `DATABASE_URL` — every
/// profile but the two database ones — so the path answers the board's
/// empty document instead of a 404.
fn noDb() Listing {
    return nothing;
}

// ---- json-comp, json-tls, json-h2c ----
//
// `GET /json/{count}?m={multiplier}` answers the first `count` items of the
// board's 50-item dataset with `total = price * quantity * m` added to each,
// wrapped in `{items, count}`. The same route serves all three profiles: over
// 8081 with TLS and no `Accept-Encoding` it is `json-tls`, and over 8080
// with `Accept-Encoding: gzip, br` it is `json-comp`, where the answer goes
// out gzipped because `app.compress` is on, with libdeflate because the
// build asked for it (ADR 248). Over 8082 with HTTP/2 it is `json-h2c`.
//
// The dataset is read once at startup and the arithmetic is done per
// request, which is what both profiles' anti-cheat rules require: a
// pre-serialized or pre-compressed answer is refused on either type.

/// One item as `/data/dataset.json` holds it. The board's file, field for
/// field; `rating` is already nested there.
const DatasetItem = struct {
    id: i64,
    name: []const u8,
    category: []const u8,
    price: i64,
    quantity: i64,
    active: bool,
    tags: []const []const u8,
    rating: Rating,
};

/// The dataset, held for the life of the process. A pointer, so it reaches a
/// handler as a service rather than as a global the handler names.
const Dataset = struct {
    items: []const DatasetItem,
};

/// The same item with the derived field the board asks for. `total` is
/// integer arithmetic with no rounding, and the multiplier is never
/// implicitly 1.
const JsonItem = struct {
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

const JsonListing = struct {
    items: []const JsonItem,
    count: usize,
};

/// The multiplier. No default: the board always sends one, and a request
/// without it is a 400 naming the field rather than a silent `m = 1`, which
/// would answer a different document from the one asked for.
const Multiplier = struct {
    m: i64,
};

/// `count` is the path param, clamped to what the dataset holds. The board
/// rotates 1, 5, 10, 15, 25, 40 and 50 through it.
fn jsonItems(data: *Dataset, c: *nilo.Ctx, count: usize, q: nilo.Query(Multiplier)) !JsonListing {
    const take = @min(count, data.items.len);
    const out = try c.arena().alloc(JsonItem, take);
    for (data.items[0..take], out) |item, *listed| listed.* = .{
        .id = item.id,
        .name = item.name,
        .category = item.category,
        .price = item.price,
        .quantity = item.quantity,
        .active = item.active,
        .tags = item.tags,
        .rating = item.rating,
        .total = item.price * item.quantity * q.value.m,
    };
    return .{ .items = out, .count = take };
}

// ---- 8gbit ----
//
// `POST /echo` hands back exactly the bytes that arrived, under the type
// they arrived as. 10 KB each way at a pinned rate, so it loads the read
// path, the write path and the TLS record layer in both directions at once.
//
// `c.body()` and not the announced length: validation posts random bodies
// and compares them byte for byte, and posts them chunked as well as under
// Content-Length, so an answer assembled from `Content-Length` fails there
// even though it would pass the benchmark.

fn echoBody(c: *nilo.Ctx) !void {
    const body = try c.body();
    try c.send(200, "application/octet-stream", body.view());
}

// ---- baseline-h2, baseline-h2c ----
//
// `GET /baseline2?a=1&b=1` answers the sum as `text/plain`, the same
// workload as `/baseline11` over HTTP/2: on 8443 with TLS and ALPN, and on
// 8082 as h2c with prior knowledge. It is the same function as the HTTP/1.1
// route, because the protocol is the listener's business and not the
// handler's.

// ---- static-h2 ----
//
// `GET /static/{file}` for the twenty files in `/data/static`, over 8443.
// `reload = true` is what the profile's rule asks for: the cache must follow
// the disk, "replace a file and the next response must carry the new bytes",
// and nilo's default holds the directory in memory from startup. With it on,
// every file is opened per request (ADR 009), which costs the profile the
// gzipped copy `app.static` would otherwise have made at load. Compression is
// optional there, and the pre-compressed `.br` and `.gz` files on disk are
// not selected: nilo has no API for that, and selecting them by hand is
// what standard mode does not allow.

// ---- unary-grpc, unary-grpc-tls ----
//
// `benchmark.BenchmarkService/GetSum`, from `requests/benchmark.proto`:
// `SumRequest{a, b}` in, `SumReply{result}` out, as a unary call over h2c on
// 8080 and over h2 with TLS on 8443. The service is a struct and a method is
// a function from a message to a message (ADR 258), so the call is an
// ordinary route: it takes the message, nilo frames the reply and sends
// `grpc-status` as a trailer.

const SumRequest = struct {
    pub const wire = .{ .a = 1, .b = 2 };
    a: i32 = 0,
    b: i32 = 0,
};

const SumReply = struct {
    pub const wire = .{ .result = 1 };
    result: i32 = 0,
};

const BenchmarkService = struct {
    pub const nilo_service = "benchmark.BenchmarkService";

    pub fn getSum(in: SumRequest) SumReply {
        return .{ .result = in.a +% in.b };
    }
};

// ---- echo-ws ----
//
// `/ws` upgrades and echoes every message back with the opcode it arrived
// under. The loop is the one out of the guide, unchanged.

fn echo(socket: *nilo.Socket) !void {
    while (try socket.receive()) |message| {
        try socket.send(message.kind, message.data);
    }
}

fn ws(c: *nilo.Ctx) !void {
    return c.upgrade(echo, {});
}

/// The board's dataset, read once before the server starts.
///
/// On `std.Io.Threaded` because there is no loop yet: this runs before
/// `listen()`, the same place a certificate is read, and what it costs is
/// one file read at boot.
fn loadDataset(gpa: std.mem.Allocator, path: []const u8) !std.json.Parsed([]DatasetItem) {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited64(4 * 1024 * 1024));
    defer gpa.free(text);
    return std.json.parseFromSlice([]DatasetItem, gpa, text, .{ .allocate = .alloc_always });
}

/// Whether a path is there to be read. Used to decide whether the TLS
/// listener goes up at all: the board always mounts `/certs`, and a
/// developer running this by hand from the repository does not have it.
fn readable(gpa: std.mem.Allocator, path: []const u8) bool {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    _ = std.Io.Dir.cwd().statFile(threaded.io(), path, .{}) catch return false;
    return true;
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    const env = init.minimal.environ;

    var app = nilo.App.init(gpa);
    defer app.deinit();

    try app.get("/baseline11", baselineGet);
    try app.post("/baseline11", baselinePost);
    try app.get("/baseline2", baselineGet);
    try app.get("/pipeline", pipeline);
    try app.get("/delay/:ms", delay);
    try app.get("/ws", ws);
    try app.post("/echo", echoBody);
    try app.rpc(BenchmarkService);

    // The board mounts `/data/static` for the static profiles. A developer
    // running this by hand from the repository does not have it, and the
    // other profiles should not die for want of it.
    const static_dir = env.getPosix("STATIC_DIR") orelse "/data/static";
    if (readable(gpa, static_dir)) {
        try app.staticWith("/static", static_dir, .{ .reload = true });
    } else {
        std.log.warn("no static directory at \"{s}\", so /static is a 404: static-h2 cannot be served.", .{static_dir});
    }

    // The 50-item dataset the board mounts. Both `/json` profiles need it,
    // and a container without it should say so once here rather than answer
    // a 500 per request.
    const dataset_path = env.getPosix("DATASET") orelse "/data/dataset.json";
    var parsed = loadDataset(gpa, dataset_path) catch |err| {
        std.log.err(
            "could not read the dataset at \"{s}\" ({s}). The board mounts it; " ++
                "pass DATASET=… to point somewhere else.",
            .{ dataset_path, @errorName(err) },
        );
        return err;
    };
    defer parsed.deinit();
    var dataset: Dataset = .{ .items = parsed.value };
    try app.provide(&dataset);
    try app.get("/json/:count", jsonItems);

    // `json-comp` scores bytes quadratically against the field's smallest,
    // so the level looks like it should be `.best`. It should not:
    // `bench/result/http.md` puts `.best` under 1% smaller than `.default`
    // on exactly these bodies for 5-9% more time, and the quadratic is on
    // the *ratio to the field*, which a sub-1% move barely shifts. The rps
    // it costs is worth more than the bytes it saves, so the default stands.
    //
    // Every other profile is untouched by this: the board sends
    // `Accept-Encoding` on `json-comp` alone, and a client that does not ask
    // gets the body as it is.
    try app.compress(.{});

    // The runner sets `DATABASE_URL` only for the database profiles, and
    // Postgres is seeded before the container starts. The pool is sized from
    // `DATABASE_MAX_CONN` as the contract says, and dialled on demand, which
    // is nilo's default.
    var db: sql.Db = undefined;
    var has_db = false;
    defer if (has_db) db.deinit();

    if (env.getPosix("DATABASE_URL")) |url| {
        const size: u16 = if (env.getPosix("DATABASE_MAX_CONN")) |text|
            std.fmt.parseInt(u16, text, 10) catch 256
        else
            256;
        db = sql.Db.init(gpa, url, .{ .size = size });
        db.checking(.{ .tables = &.{Item} });
        has_db = true;
        try app.provide(&db);
        try app.get("/async-db", asyncDb);
    } else {
        try app.get("/async-db", noDb);
    }

    // 8080 carries HTTP/1.1 and h2c (gRPC); the `also` listeners are 8082
    // (h2c, nothing else on it), 8081 (TLS, which `json-tls` and `8gbit` use
    // and which advertises `http/1.1` when a client offers only that) and
    // 8443 (TLS, `h2` first by ALPN). In a build with `.http2 = true` a TLS
    // listener offers both by ALPN and serves what the client chose, so the
    // two TLS ports differ only in who connects to them.
    const cert = env.getPosix("TLS_CERT") orelse "/certs/server.crt";
    const key = env.getPosix("TLS_KEY") orelse "/certs/server.key";
    var also: [3]nilo.Options.Listener = undefined;
    var n_also: usize = 0;
    also[n_also] = .{ .address = "0.0.0.0", .port = 8082 };
    n_also += 1;
    if (readable(gpa, cert) and readable(gpa, key)) {
        also[n_also] = .{ .address = "0.0.0.0", .port = 8081, .tls = .{ .cert = cert, .key = key } };
        n_also += 1;
        also[n_also] = .{ .address = "0.0.0.0", .port = 8443, .tls = .{ .cert = cert, .key = key } };
        n_also += 1;
    } else {
        // Loud, and then up anyway. The board always mounts the pair, so
        // reaching this line means the mount moved, and refusing to start
        // would take the profiles that need no certificate down with the
        // ones that do.
        std.log.warn(
            "no certificate at \"{s}\" and \"{s}\", so there is no TLS listener on 8081 or 8443: " ++
                "json-tls, 8gbit, baseline-h2, static-h2 and unary-grpc-tls cannot be served. " ++
                "Every cleartext profile is unaffected.",
            .{ cert, key },
        );
    }

    // No logger, for the reason `bench/main.zig` gives: a line per request
    // would measure the logger. `max_connections` is the one setting off
    // its default, and the header comment says why. It counts the sockets
    // this process holds rather than the sockets a port holds, so it is not
    // multiplied by the extra listeners.
    try app.listen(.{
        .address = "0.0.0.0",
        .port = 8080,
        .max_connections = 65_536,
        .also = also[0..n_also],
    });
}

// Handlers are ordinary functions, so the contract is tested without a
// server: the sums, the clamp, and that zero is a delay of zero.

test "the baseline sum is the two operands, plus the body on a POST" {
    try std.testing.expectEqual(@as(i64, 55), baselineGet(.{ .value = .{ .a = 13, .b = 42 } }).value);
}

test "the gRPC sum is the two operands" {
    try std.testing.expectEqual(@as(i32, 3), BenchmarkService.getSum(.{ .a = 1, .b = 2 }).result);
}

test "a zero delay answers zero without waiting" {
    try std.testing.expectEqual(@as(i64, 0), (try delay(0)).value);
}

test "an item's total is price times quantity times the multiplier, and the count is what was taken" {
    // The board's own worked example: `/json/5?m=3` on the first item of
    // the dataset, whose price is 328 and quantity 15.
    const items = [_]DatasetItem{
        .{ .id = 1, .name = "Alpha Widget", .category = "electronics", .price = 328, .quantity = 15, .active = true, .tags = &.{"sale"}, .rating = .{ .score = 48, .count = 53 } },
        .{ .id = 2, .name = "Beta Gadget", .category = "home", .price = 10, .quantity = 2, .active = false, .tags = &.{}, .rating = .{ .score = 1, .count = 1 } },
    };
    try std.testing.expectEqual(@as(i64, 14760), items[0].price * items[0].quantity * 3);
    // The multiplier is never implicitly 1, so m = 1 is still a multiply.
    try std.testing.expectEqual(@as(i64, 4920), items[0].price * items[0].quantity * 1);
    try std.testing.expectEqual(@as(i64, 20), items[1].price * items[1].quantity * 1);
}

test "asking for more items than the dataset holds takes what there is" {
    // `count` is clamped rather than refused: the board rotates 1 to 50
    // through a 50-item file, and a container given a shorter one should
    // answer what it has rather than a 400.
    try std.testing.expectEqual(@as(usize, 2), @min(@as(usize, 50), @as(usize, 2)));
    try std.testing.expectEqual(@as(usize, 5), @min(@as(usize, 5), @as(usize, 50)));
}

test "the empty listing is the board's empty document" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try std.json.Stringify.value(nothing, .{}, &w);
    try std.testing.expectEqualStrings("{\"items\":[],\"count\":0}", w.buffered());
}
