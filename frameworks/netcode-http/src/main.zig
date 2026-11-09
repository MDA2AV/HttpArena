//! netcode-http's routes on quic-zig's event loop, one loop per core sharing
//! the ports (SO_REUSEPORT): HTTP/1.1 and WebSocket on 8080, HTTP/3 on 8443.

const std = @import("std");
const quic = @import("quic");
const http = @import("http");
const event_loop = quic.event_loop;

pub const std_options: std.Options = .{ .log_level = .warn };

const Worker = struct {
    pub const protocol: event_loop.Protocol = .h3;

    router: http.Router,
    host: http.quic.Host,
    // The Host's, kept here: it may live no longer than a callback.
    sockets: http.Sockets = .{},
    pendings: http.quic.Pendings = .{},

    // HTTP/1.1 and HTTP/3 requests alike.
    pub fn onHttpHead(self: *Worker, ex: *event_loop.Exchange) void {
        self.host.onHttpHead(ex);
    }
    pub fn onHttpBody(self: *Worker, ex: *event_loop.Exchange, data: []const u8) void {
        self.host.onHttpBody(ex, data);
    }
    pub fn onHttpEnd(self: *Worker, ex: *event_loop.Exchange) void {
        self.host.onHttpEnd(ex);
    }
    pub fn onHttpGone(self: *Worker, ex: *event_loop.Exchange) void {
        self.host.onHttpGone(ex);
    }

    pub fn onWsUpgrade(self: *Worker, req: *event_loop.WsRequest, path: []const u8) void {
        self.host.onWsUpgrade(req, path);
    }
    pub fn onWsMessage(self: *Worker, ws: *event_loop.WsConn, data: []const u8, kind: http.WebSocket.Kind) void {
        self.host.onWsMessage(ws, data, kind);
    }
    pub fn onWsClose(self: *Worker, ws: *event_loop.WsConn, code: u16, reason: []const u8) void {
        self.host.onWsClose(ws, code, reason);
    }
};

const Sum = struct { a: i64 = 0, b: i64 = 0 };

fn baseline(ctx: *http.Context(.{ .query = Sum, .body = []const u8 })) !void {
    var sum = ctx.query.a + ctx.query.b;
    const body = std.mem.trim(u8, ctx.body, " \t\r\n");
    if (body.len > 0) sum += std.fmt.parseInt(i64, body, 10) catch return error.BadRequest;
    var buf: [24]u8 = undefined;
    try ctx.text(200, try std.fmt.bufPrint(&buf, "{d}", .{sum}));
}

fn pipeline(ctx: *http.Context(.{})) !void {
    try ctx.text(200, "ok");
}

// Reached only without `Upgrade: websocket`, which goes to `Echo`.
fn wsWithoutUpgrade(ctx: *http.Context(.{})) !void {
    try ctx.text(426, "Upgrade Required\n");
}

const Echo = struct {
    pub fn open(_: *http.Context(.{})) !void {}

    pub fn message(ws: *http.WebSocket, data: []const u8, kind: http.WebSocket.Kind) void {
        const sent = switch (kind) {
            .text => ws.sendText(data),
            .binary => ws.send(data),
        };
        sent catch ws.close(1011, "");
    }
};

fn routes(r: *http.Router) !void {
    try r.get("/baseline11", {}, baseline);
    try r.post("/baseline11", {}, baseline);
    try r.get("/baseline2", {}, baseline);
    try r.get("/pipeline", {}, pipeline);
    try r.get("/ws", {}, wsWithoutUpgrade);
    try r.ws("/ws", {}, Echo);
}

fn serve(gpa: std.mem.Allocator) !void {
    const w = try gpa.create(Worker);
    w.* = .{ .router = .init(gpa), .host = undefined };
    w.host = .init(gpa, &w.router);
    w.host.sockets = &w.sockets;
    w.host.pendings = &w.pendings;
    try routes(&w.router);

    var server = try event_loop.Server(Worker).init(gpa, w, .{
        .address = "0.0.0.0",
        .port = 8443,
        .cert_path = "/certs/server.crt",
        .key_path = "/certs/server.key",
        .reuse_port = true,
        .http1 = .{ .port = 8080, .tls = false, .alt_svc = false, .max_connections = 65536 },
    });
    try server.run();
}

fn serveOrDie(gpa: std.mem.Allocator) void {
    serve(gpa) catch |err| {
        std.log.err("worker: {t}", .{err});
        std.process.exit(1);
    };
}

// PID 1 in the container: without a handler SIGTERM is ignored and docker stop waits out its timeout.
fn onTerm(_: std.posix.SIG) callconv(.c) void {
    std.process.exit(0);
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    const term: std.posix.Sigaction = .{ .handler = .{ .handler = onTerm }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.TERM, &term, null);
    std.posix.sigaction(.INT, &term, null);

    const workers = if (init.environ_map.get("WORKERS")) |v|
        try std.fmt.parseInt(usize, v, 10)
    else
        std.Thread.getCpuCount() catch 1;

    for (1..workers) |_| (try std.Thread.spawn(.{}, serveOrDie, .{gpa})).detach();
    serveOrDie(gpa);
}
