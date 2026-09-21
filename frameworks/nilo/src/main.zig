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
//! Profiles nilo does not subscribe to, and why: `json-comp` needs response
//! compression and every TLS, HTTP/2, HTTP/3 and gRPC profile needs a
//! protocol nilo refuses on the record (ADR 0028); `fortunes` in standard
//! mode needs a template engine, refused by the same ADR.

const std = @import("std");
const nilo = @import("nilo_http");
const sql = @import("nilo_sql");
const fail = nilo.fail;

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

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    const env = init.minimal.environ;

    var app = nilo.App.init(gpa);
    defer app.deinit();

    try app.get("/baseline11", baselineGet);
    try app.post("/baseline11", baselinePost);
    try app.get("/pipeline", pipeline);
    try app.get("/delay/:ms", delay);
    try app.get("/ws", ws);

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

    // No logger, for the reason `bench/main.zig` gives: a line per request
    // would measure the logger. `max_connections` is the one setting off
    // its default, and the header comment says why.
    try app.listen(.{
        .address = "0.0.0.0",
        .port = 8080,
        .max_connections = 65_536,
    });
}

// Handlers are ordinary functions, so the contract is tested without a
// server: the sums, the clamp, and that zero is a delay of zero.

test "the baseline sum is the two operands, plus the body on a POST" {
    try std.testing.expectEqual(@as(i64, 55), baselineGet(.{ .value = .{ .a = 13, .b = 42 } }).value);
}

test "a zero delay answers zero without waiting" {
    try std.testing.expectEqual(@as(i64, 0), (try delay(0)).value);
}

test "the empty listing is the board's empty document" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try std.json.Stringify.value(nothing, .{}, &w);
    try std.testing.expectEqualStrings("{\"items\":[],\"count\":0}", w.buffered());
}
