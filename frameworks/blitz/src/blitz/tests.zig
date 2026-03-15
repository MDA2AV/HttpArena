const std = @import("std");
const testing = std.testing;
const mem = std.mem;

const types = @import("types.zig");
const router_mod = @import("router.zig");
const parser_mod = @import("parser.zig");
const json_mod = @import("json.zig");
const errors_mod = @import("errors.zig");
const static_mod = @import("static.zig");
const query_mod = @import("query.zig");
const pool_mod = @import("pool.zig");
const body_mod = @import("body.zig");
const cookie_mod = @import("cookie.zig");

const Method = types.Method;
const StatusCode = types.StatusCode;
const Headers = types.Headers;
const Request = types.Request;
const Response = types.Response;
const Router = router_mod.Router;
const Group = router_mod.Group;

// ════════════════════════════════════════════════════════════════════
// Method tests
// ════════════════════════════════════════════════════════════════════

test "Method.fromString parses valid methods" {
    try testing.expectEqual(Method.GET, Method.fromString("GET").?);
    try testing.expectEqual(Method.POST, Method.fromString("POST").?);
    try testing.expectEqual(Method.PUT, Method.fromString("PUT").?);
    try testing.expectEqual(Method.DELETE, Method.fromString("DELETE").?);
    try testing.expectEqual(Method.PATCH, Method.fromString("PATCH").?);
    try testing.expectEqual(Method.HEAD, Method.fromString("HEAD").?);
    try testing.expectEqual(Method.OPTIONS, Method.fromString("OPTIONS").?);
}

test "Method.fromString rejects invalid methods" {
    try testing.expect(Method.fromString("CONNECT") == null);
    try testing.expect(Method.fromString("") == null);
    try testing.expect(Method.fromString("X") == null);
    try testing.expect(Method.fromString("get") == null); // case sensitive
    try testing.expect(Method.fromString("GETS") == null);
}

// ════════════════════════════════════════════════════════════════════
// StatusCode tests
// ════════════════════════════════════════════════════════════════════

test "StatusCode.code returns numeric value" {
    try testing.expectEqual(@as(u16, 200), StatusCode.ok.code());
    try testing.expectEqual(@as(u16, 404), StatusCode.not_found.code());
    try testing.expectEqual(@as(u16, 500), StatusCode.internal_server_error.code());
}

test "StatusCode.phrase returns reason phrase" {
    try testing.expectEqualStrings("OK", StatusCode.ok.phrase());
    try testing.expectEqualStrings("Not Found", StatusCode.not_found.phrase());
    try testing.expectEqualStrings("Internal Server Error", StatusCode.internal_server_error.phrase());
}

// ════════════════════════════════════════════════════════════════════
// Headers tests
// ════════════════════════════════════════════════════════════════════

test "Headers.set and get" {
    var h = Headers{};
    h.set("Content-Type", "text/plain");
    try testing.expectEqualStrings("text/plain", h.get("Content-Type").?);
    try testing.expectEqualStrings("text/plain", h.get("content-type").?); // case insensitive
    try testing.expect(h.get("X-Missing") == null);
}

test "Headers.set replaces existing" {
    var h = Headers{};
    h.set("Content-Type", "text/plain");
    h.set("Content-Type", "application/json");
    try testing.expectEqualStrings("application/json", h.get("Content-Type").?);
    try testing.expectEqual(@as(usize, 1), h.len);
}

test "Headers.append allows duplicates" {
    var h = Headers{};
    h.append("Set-Cookie", "a=1");
    h.append("Set-Cookie", "b=2");
    try testing.expectEqual(@as(usize, 2), h.len);
    // get() returns first match
    try testing.expectEqualStrings("a=1", h.get("Set-Cookie").?);
}

// ════════════════════════════════════════════════════════════════════
// Request tests
// ════════════════════════════════════════════════════════════════════

test "Request.queryParam parses query string" {
    const req = Request{
        .method = .GET,
        .path = "/search",
        .query = "q=hello&page=2&lang=en",
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    try testing.expectEqualStrings("hello", req.queryParam("q").?);
    try testing.expectEqualStrings("2", req.queryParam("page").?);
    try testing.expectEqualStrings("en", req.queryParam("lang").?);
    try testing.expect(req.queryParam("missing") == null);
}

test "Request.queryParam with no query" {
    const req = Request{
        .method = .GET,
        .path = "/",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    try testing.expect(req.queryParam("q") == null);
}

test "Request.Params.get and set" {
    var p = Request.Params{};
    p.set("id", "42");
    p.set("name", "alice");
    try testing.expectEqualStrings("42", p.get("id").?);
    try testing.expectEqualStrings("alice", p.get("name").?);
    try testing.expect(p.get("missing") == null);
}

// ════════════════════════════════════════════════════════════════════
// Response tests
// ════════════════════════════════════════════════════════════════════

test "Response.text sets body and content type" {
    var res = Response{};
    _ = res.text("hello");
    try testing.expectEqualStrings("hello", res.body.?);
    try testing.expectEqualStrings("text/plain", res.headers.get("Content-Type").?);
}

test "Response.json sets body and content type" {
    var res = Response{};
    _ = res.json("{\"ok\":true}");
    try testing.expectEqualStrings("{\"ok\":true}", res.body.?);
    try testing.expectEqualStrings("application/json", res.headers.get("Content-Type").?);
}

test "Response.html sets body and content type" {
    var res = Response{};
    _ = res.html("<h1>hi</h1>");
    try testing.expectEqualStrings("<h1>hi</h1>", res.body.?);
    try testing.expectEqualStrings("text/html", res.headers.get("Content-Type").?);
}

test "Response.setStatus chains" {
    var res = Response{};
    _ = res.setStatus(.not_found).text("nope");
    try testing.expectEqual(StatusCode.not_found, res.status);
    try testing.expectEqualStrings("nope", res.body.?);
}

test "Response.rawResponse bypasses serialization" {
    var res = Response{};
    const raw = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";
    _ = res.rawResponse(raw);
    try testing.expectEqualStrings(raw, res.raw.?);
}

test "Response.writeTo serializes correctly" {
    var res = Response{};
    _ = res.text("hello");

    var out = std.ArrayList(u8).init(testing.allocator);
    defer out.deinit();
    res.writeTo(&out);

    const output = out.items;
    try testing.expect(mem.startsWith(u8, output, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(mem.indexOf(u8, output, "Server: blitz") != null);
    try testing.expect(mem.indexOf(u8, output, "Content-Type: text/plain") != null);
    try testing.expect(mem.indexOf(u8, output, "Content-Length: 5") != null);
    try testing.expect(mem.endsWith(u8, output, "\r\n\r\nhello"));
}

test "Response.writeTo with raw response" {
    var res = Response{};
    const raw = "HTTP/1.1 204 No Content\r\n\r\n";
    _ = res.rawResponse(raw);

    var out = std.ArrayList(u8).init(testing.allocator);
    defer out.deinit();
    res.writeTo(&out);

    try testing.expectEqualStrings(raw, out.items);
}

// ════════════════════════════════════════════════════════════════════
// Router tests
// ════════════════════════════════════════════════════════════════════

fn dummyHandler(_: *Request, res: *Response) void {
    _ = res.text("ok");
}

fn userHandler(req: *Request, res: *Response) void {
    const id = req.params.get("id") orelse "?";
    _ = res.text(id);
}

fn wildcardHandler(req: *Request, res: *Response) void {
    const fp = req.params.get("filepath") orelse "?";
    _ = res.text(fp);
}

test "Router matches static routes" {
    var router = Router.init(std.heap.page_allocator);
    router.get("/", dummyHandler);
    router.get("/hello", dummyHandler);
    router.get("/hello/world", dummyHandler);

    var p = Request.Params{};
    try testing.expect(router.match(.GET, "/", &p) != null);
    try testing.expect(router.match(.GET, "/hello", &p) != null);
    try testing.expect(router.match(.GET, "/hello/world", &p) != null);
    try testing.expect(router.match(.GET, "/nope", &p) == null);
    try testing.expect(router.match(.POST, "/hello", &p) == null); // wrong method
}

test "Router matches param routes" {
    var router = Router.init(std.heap.page_allocator);
    router.get("/users/:id", userHandler);

    var p = Request.Params{};
    const handler = router.match(.GET, "/users/42", &p);
    try testing.expect(handler != null);
    try testing.expectEqualStrings("42", p.get("id").?);
}

test "Router matches nested params" {
    var router = Router.init(std.heap.page_allocator);
    router.get("/users/:uid/posts/:pid", dummyHandler);

    var p = Request.Params{};
    const handler = router.match(.GET, "/users/5/posts/10", &p);
    try testing.expect(handler != null);
    try testing.expectEqualStrings("5", p.get("uid").?);
    try testing.expectEqualStrings("10", p.get("pid").?);
}

test "Router matches wildcard routes" {
    var router = Router.init(std.heap.page_allocator);
    router.get("/static/*filepath", wildcardHandler);

    var p = Request.Params{};
    const handler = router.match(.GET, "/static/css/style.css", &p);
    try testing.expect(handler != null);
    try testing.expectEqualStrings("css/style.css", p.get("filepath").?);
}

test "Router static takes priority over param" {
    var router = Router.init(std.heap.page_allocator);

    const staticHandler = struct {
        fn f(_: *Request, res: *Response) void {
            _ = res.text("static");
        }
    }.f;
    const paramHandler = struct {
        fn f(_: *Request, res: *Response) void {
            _ = res.text("param");
        }
    }.f;

    router.get("/users/me", staticHandler);
    router.get("/users/:id", paramHandler);

    // /users/me should match static, not param
    var p = Request.Params{};
    const handler = router.match(.GET, "/users/me", &p).?;
    var req = Request{
        .method = .GET,
        .path = "/users/me",
        .query = null,
        .headers = .{},
        .body = null,
        .params = p,
        .raw_header = "",
    };
    var res = Response{};
    handler(&req, &res);
    try testing.expectEqualStrings("static", res.body.?);
}

test "Router handle calls 404 for unknown routes" {
    var router = Router.init(std.heap.page_allocator);
    router.get("/", dummyHandler);

    var req = Request{
        .method = .GET,
        .path = "/missing",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    router.handle(&req, &res);
    try testing.expectEqual(StatusCode.not_found, res.status);
}

test "Router custom 404 handler" {
    var router = Router.init(std.heap.page_allocator);
    router.notFound(struct {
        fn f(_: *Request, res: *Response) void {
            _ = res.setStatus(.not_found).json("{\"error\":\"not found\"}");
        }
    }.f);

    var req = Request{
        .method = .GET,
        .path = "/missing",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    router.handle(&req, &res);
    try testing.expectEqual(StatusCode.not_found, res.status);
    try testing.expectEqualStrings("{\"error\":\"not found\"}", res.body.?);
}

// ════════════════════════════════════════════════════════════════════
// Middleware tests
// ════════════════════════════════════════════════════════════════════

test "Middleware runs before handler" {
    var router = Router.init(std.heap.page_allocator);

    // Middleware that adds a header
    router.use(struct {
        fn f(_: *Request, res: *Response) bool {
            res.headers.set("X-Middleware", "ran");
            return true;
        }
    }.f);

    router.get("/", struct {
        fn f(_: *Request, res: *Response) void {
            _ = res.text("ok");
        }
    }.f);

    var req = Request{
        .method = .GET,
        .path = "/",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    router.handle(&req, &res);
    try testing.expectEqualStrings("ok", res.body.?);
    try testing.expectEqualStrings("ran", res.headers.get("X-Middleware").?);
}

test "Middleware can short-circuit" {
    var router = Router.init(std.heap.page_allocator);

    // Auth middleware that blocks
    router.use(struct {
        fn f(_: *Request, res: *Response) bool {
            _ = res.setStatus(.unauthorized).text("denied");
            return false;
        }
    }.f);

    router.get("/", struct {
        fn f(_: *Request, res: *Response) void {
            _ = res.text("should not reach");
        }
    }.f);

    var req = Request{
        .method = .GET,
        .path = "/",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    router.handle(&req, &res);
    try testing.expectEqual(StatusCode.unauthorized, res.status);
    try testing.expectEqualStrings("denied", res.body.?);
}

test "Multiple middleware run in order" {
    var router = Router.init(std.heap.page_allocator);

    router.use(struct {
        fn f(_: *Request, res: *Response) bool {
            res.headers.set("X-Order", "first");
            return true;
        }
    }.f);

    router.use(struct {
        fn f(_: *Request, res: *Response) bool {
            // Overwrite to prove second ran after first
            res.headers.set("X-Order", "second");
            return true;
        }
    }.f);

    router.get("/", dummyHandler);

    var req = Request{
        .method = .GET,
        .path = "/",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    router.handle(&req, &res);
    try testing.expectEqualStrings("second", res.headers.get("X-Order").?);
}

// ════════════════════════════════════════════════════════════════════
// Route Group tests
// ════════════════════════════════════════════════════════════════════

test "Route group registers prefixed routes" {
    var router = Router.init(std.heap.page_allocator);
    const api = router.group("/api/v1");
    api.get("/users", dummyHandler);
    api.post("/users", dummyHandler);

    var p = Request.Params{};
    try testing.expect(router.match(.GET, "/api/v1/users", &p) != null);
    try testing.expect(router.match(.POST, "/api/v1/users", &p) != null);
    try testing.expect(router.match(.GET, "/users", &p) == null); // without prefix
}

test "Route group with params" {
    var router = Router.init(std.heap.page_allocator);
    const api = router.group("/api");
    api.get("/users/:id", userHandler);

    var p = Request.Params{};
    const handler = router.match(.GET, "/api/users/99", &p);
    try testing.expect(handler != null);
    try testing.expectEqualStrings("99", p.get("id").?);
}

test "Nested route groups" {
    var router = Router.init(std.heap.page_allocator);
    const api = router.group("/api");
    const v2 = api.group("/v2");
    v2.get("/health", dummyHandler);

    var p = Request.Params{};
    try testing.expect(router.match(.GET, "/api/v2/health", &p) != null);
}

// ════════════════════════════════════════════════════════════════════
// Parser tests
// ════════════════════════════════════════════════════════════════════

test "Parser parses simple GET request" {
    const data = "GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const result = parser_mod.parse(data).?;
    try testing.expectEqual(Method.GET, result.request.method);
    try testing.expectEqualStrings("/hello", result.request.path);
    try testing.expect(result.request.query == null);
    try testing.expect(result.request.body == null);
    try testing.expectEqual(data.len, result.total_len);
}

test "Parser parses GET with query string" {
    const data = "GET /search?q=zig&page=1 HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const result = parser_mod.parse(data).?;
    try testing.expectEqualStrings("/search", result.request.path);
    try testing.expectEqualStrings("q=zig&page=1", result.request.query.?);
}

test "Parser parses POST with body" {
    const data = "POST /data HTTP/1.1\r\nHost: localhost\r\nContent-Length: 13\r\n\r\nHello, World!";
    const result = parser_mod.parse(data).?;
    try testing.expectEqual(Method.POST, result.request.method);
    try testing.expectEqualStrings("/data", result.request.path);
    try testing.expectEqualStrings("Hello, World!", result.request.body.?);
    try testing.expectEqual(data.len, result.total_len);
}

test "Parser parses headers" {
    const data = "GET / HTTP/1.1\r\nHost: example.com\r\nAccept: text/html\r\nX-Custom: foo\r\n\r\n";
    const result = parser_mod.parse(data).?;
    try testing.expectEqualStrings("example.com", result.request.headers.get("Host").?);
    try testing.expectEqualStrings("text/html", result.request.headers.get("Accept").?);
    try testing.expectEqualStrings("foo", result.request.headers.get("X-Custom").?);
}

test "Parser returns null for incomplete request" {
    const data = "GET /hello HTTP/1.1\r\nHost: localhost\r\n"; // no \r\n\r\n
    try testing.expect(parser_mod.parse(data) == null);
}

test "Parser returns null for incomplete body" {
    const data = "POST /data HTTP/1.1\r\nContent-Length: 100\r\n\r\nshort";
    try testing.expect(parser_mod.parse(data) == null);
}

test "Parser handles pipelined requests" {
    const req1 = "GET /a HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const req2 = "GET /b HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const data = req1 ++ req2;

    const r1 = parser_mod.parse(data).?;
    try testing.expectEqualStrings("/a", r1.request.path);
    try testing.expectEqual(req1.len, r1.total_len);

    const r2 = parser_mod.parse(data[r1.total_len..]).?;
    try testing.expectEqualStrings("/b", r2.request.path);
}

// ════════════════════════════════════════════════════════════════════
// Utility tests
// ════════════════════════════════════════════════════════════════════

test "asciiEqlIgnoreCase" {
    try testing.expect(types.asciiEqlIgnoreCase("Content-Type", "content-type"));
    try testing.expect(types.asciiEqlIgnoreCase("HOST", "host"));
    try testing.expect(!types.asciiEqlIgnoreCase("abc", "abd"));
    try testing.expect(!types.asciiEqlIgnoreCase("ab", "abc"));
}

test "writeUsize" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0", types.writeUsize(&buf, 0));
    try testing.expectEqualStrings("42", types.writeUsize(&buf, 42));
    try testing.expectEqualStrings("12345", types.writeUsize(&buf, 12345));
}

test "writeI64" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0", types.writeI64(&buf, 0));
    try testing.expectEqualStrings("42", types.writeI64(&buf, 42));
    try testing.expectEqualStrings("-7", types.writeI64(&buf, -7));
}

// ════════════════════════════════════════════════════════════════════
// JSON builder tests
// ════════════════════════════════════════════════════════════════════

const Json = json_mod.Json;
const JsonObject = json_mod.JsonObject;
const JsonArray = json_mod.JsonArray;

test "Json.stringify string" {
    var buf: [256]u8 = undefined;
    const result = Json.stringify(&buf, "hello").?;
    try testing.expectEqualStrings("\"hello\"", result);
}

test "Json.stringify string escaping" {
    var buf: [256]u8 = undefined;
    const result = Json.stringify(&buf, "he said \"hi\"\nnewline").?;
    try testing.expectEqualStrings("\"he said \\\"hi\\\"\\nnewline\"", result);
}

test "Json.stringify integers" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("42", Json.stringify(&buf, @as(i64, 42)).?);
    try testing.expectEqualStrings("0", Json.stringify(&buf, @as(i64, 0)).?);
    try testing.expectEqualStrings("-7", Json.stringify(&buf, @as(i64, -7)).?);
}

test "Json.stringify bool" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("true", Json.stringify(&buf, true).?);
    try testing.expectEqualStrings("false", Json.stringify(&buf, false).?);
}

test "Json.stringify optional" {
    var buf: [256]u8 = undefined;
    const some: ?i64 = 5;
    const none: ?i64 = null;
    try testing.expectEqualStrings("5", Json.stringify(&buf, some).?);
    try testing.expectEqualStrings("null", Json.stringify(&buf, none).?);
}

test "Json.stringify struct" {
    var buf: [512]u8 = undefined;
    const val = .{ .name = "Alice", .age = @as(i64, 30), .active = true };
    const result = Json.stringify(&buf, val).?;
    try testing.expectEqualStrings("{\"name\":\"Alice\",\"age\":30,\"active\":true}", result);
}

test "Json.stringify struct with optional null skipped" {
    var buf: [512]u8 = undefined;
    const T = struct {
        name: []const u8,
        email: ?[]const u8,
    };
    const val = T{ .name = "Bob", .email = null };
    const result = Json.stringify(&buf, val).?;
    try testing.expectEqualStrings("{\"name\":\"Bob\"}", result);
}

test "Json.stringify struct with optional present" {
    var buf: [512]u8 = undefined;
    const T = struct {
        name: []const u8,
        email: ?[]const u8,
    };
    const val = T{ .name = "Bob", .email = "bob@example.com" };
    const result = Json.stringify(&buf, val).?;
    try testing.expectEqualStrings("{\"name\":\"Bob\",\"email\":\"bob@example.com\"}", result);
}

test "Json.stringify slice of ints" {
    var buf: [256]u8 = undefined;
    const items = [_]i64{ 1, 2, 3 };
    const result = Json.stringify(&buf, @as([]const i64, &items)).?;
    try testing.expectEqualStrings("[1,2,3]", result);
}

test "Json.stringify enum" {
    var buf: [256]u8 = undefined;
    const Color = enum { red, green, blue };
    try testing.expectEqualStrings("\"green\"", Json.stringify(&buf, Color.green).?);
}

test "Json.stringify overflow returns null" {
    var buf: [5]u8 = undefined;
    // "hello" needs 7 bytes with quotes
    try testing.expect(Json.stringify(&buf, "hello") == null);
}

test "JsonObject basic" {
    var buf: [256]u8 = undefined;
    var obj = JsonObject.init(&buf);
    obj.field("name", "Alice");
    obj.field("age", @as(i64, 30));
    obj.field("active", true);
    const result = obj.finish().?;
    try testing.expectEqualStrings("{\"name\":\"Alice\",\"age\":30,\"active\":true}", result);
}

test "JsonObject with rawField" {
    var buf: [256]u8 = undefined;
    var obj = JsonObject.init(&buf);
    obj.field("name", "Test");
    obj.rawField("data", "[1,2,3]");
    const result = obj.finish().?;
    try testing.expectEqualStrings("{\"name\":\"Test\",\"data\":[1,2,3]}", result);
}

test "JsonArray basic" {
    var buf: [256]u8 = undefined;
    var arr = JsonArray.init(&buf);
    arr.push(@as(i64, 1));
    arr.push(@as(i64, 2));
    arr.push(@as(i64, 3));
    const result = arr.finish().?;
    try testing.expectEqualStrings("[1,2,3]", result);
}

test "JsonArray mixed types" {
    var buf: [256]u8 = undefined;
    var arr = JsonArray.init(&buf);
    arr.push("hello");
    arr.push(@as(i64, 42));
    arr.push(true);
    const result = arr.finish().?;
    try testing.expectEqualStrings("[\"hello\",42,true]", result);
}

test "JsonArray with pushRaw" {
    var buf: [256]u8 = undefined;
    var arr = JsonArray.init(&buf);
    arr.push("first");
    arr.pushRaw("{\"nested\":true}");
    const result = arr.finish().?;
    try testing.expectEqualStrings("[\"first\",{\"nested\":true}]", result);
}

// ════════════════════════════════════════════════════════════════════
// Error handling tests
// ════════════════════════════════════════════════════════════════════

test "sendError with custom message produces raw response" {
    var res = Response{};
    errors_mod.sendError(&res, .bad_request, "Missing field");
    // Custom messages use rawResponse (full HTTP response)
    const raw = res.raw.?;
    try testing.expect(mem.indexOf(u8, raw, "400 Bad Request") != null);
    try testing.expect(mem.indexOf(u8, raw, "application/json") != null);
    try testing.expect(mem.indexOf(u8, raw, "\"status\":400") != null);
    try testing.expect(mem.indexOf(u8, raw, "\"message\":\"Missing field\"") != null);
}

test "sendError with empty message uses pre-computed response" {
    var res = Response{};
    errors_mod.sendError(&res, .not_found, "");
    try testing.expectEqual(StatusCode.not_found, res.status);
    try testing.expectEqualStrings("application/json", res.headers.get("Content-Type").?);
    const body = res.body.?;
    try testing.expect(mem.indexOf(u8, body, "\"status\":404") != null);
}

test "badRequest convenience" {
    var res = Response{};
    errors_mod.badRequest(&res, "Bad input");
    const raw = res.raw.?;
    try testing.expect(mem.indexOf(u8, raw, "\"status\":400") != null);
    try testing.expect(mem.indexOf(u8, raw, "\"message\":\"Bad input\"") != null);
}

test "notFound convenience" {
    var res = Response{};
    errors_mod.notFound(&res, "No such thing");
    const raw = res.raw.?;
    try testing.expect(mem.indexOf(u8, raw, "\"status\":404") != null);
}

test "internalError convenience" {
    var res = Response{};
    errors_mod.internalError(&res, "Something broke");
    const raw = res.raw.?;
    try testing.expect(mem.indexOf(u8, raw, "\"status\":500") != null);
    try testing.expect(mem.indexOf(u8, raw, "\"message\":\"Something broke\"") != null);
}

test "jsonNotFoundHandler" {
    var req = Request{
        .method = .GET,
        .path = "/nope",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    errors_mod.jsonNotFoundHandler(&req, &res);
    try testing.expectEqual(StatusCode.not_found, res.status);
    try testing.expectEqualStrings("application/json", res.headers.get("Content-Type").?);
}

// ════════════════════════════════════════════════════════════════════
// Static file serving tests
// ════════════════════════════════════════════════════════════════════

// ── MIME type tests ─────────────────────────────────────────────────

test "mimeFromPath returns correct MIME for common extensions" {
    try testing.expectEqualStrings("text/html; charset=utf-8", static_mod.mimeFromPath("index.html"));
    try testing.expectEqualStrings("text/css; charset=utf-8", static_mod.mimeFromPath("style.css"));
    try testing.expectEqualStrings("application/javascript; charset=utf-8", static_mod.mimeFromPath("app.js"));
    try testing.expectEqualStrings("application/json; charset=utf-8", static_mod.mimeFromPath("data.json"));
    try testing.expectEqualStrings("image/png", static_mod.mimeFromPath("logo.png"));
    try testing.expectEqualStrings("image/jpeg", static_mod.mimeFromPath("photo.jpg"));
    try testing.expectEqualStrings("image/jpeg", static_mod.mimeFromPath("photo.jpeg"));
    try testing.expectEqualStrings("image/svg+xml", static_mod.mimeFromPath("icon.svg"));
    try testing.expectEqualStrings("font/woff2", static_mod.mimeFromPath("font.woff2"));
    try testing.expectEqualStrings("application/pdf", static_mod.mimeFromPath("doc.pdf"));
    try testing.expectEqualStrings("application/wasm", static_mod.mimeFromPath("module.wasm"));
}

test "mimeFromPath handles paths with directories" {
    try testing.expectEqualStrings("text/css; charset=utf-8", static_mod.mimeFromPath("css/style.css"));
    try testing.expectEqualStrings("application/javascript; charset=utf-8", static_mod.mimeFromPath("js/bundle/app.mjs"));
}

test "mimeFromPath returns octet-stream for unknown extension" {
    try testing.expectEqualStrings("application/octet-stream", static_mod.mimeFromPath("file.xyz"));
    try testing.expectEqualStrings("application/octet-stream", static_mod.mimeFromPath("noext"));
}

test "mimeFromPath handles uppercase extensions" {
    try testing.expectEqualStrings("text/html; charset=utf-8", static_mod.mimeFromPath("index.HTML"));
    try testing.expectEqualStrings("image/png", static_mod.mimeFromPath("logo.PNG"));
}

// ── Extension extraction tests ──────────────────────────────────────

test "extensionOf extracts extension" {
    try testing.expectEqualStrings("html", static_mod.extensionOf("index.html"));
    try testing.expectEqualStrings("css", static_mod.extensionOf("path/to/style.css"));
    try testing.expectEqualStrings("gz", static_mod.extensionOf("archive.tar.gz"));
    try testing.expectEqualStrings("", static_mod.extensionOf("noext"));
    try testing.expectEqualStrings("", static_mod.extensionOf(""));
}

test "extensionOf handles dotfiles" {
    try testing.expectEqualStrings("gitignore", static_mod.extensionOf(".gitignore"));
}

// ── Path sanitization tests ─────────────────────────────────────────

test "sanitizePath allows normal paths" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("style.css", static_mod.sanitizePath(&buf, "style.css").?);
    try testing.expectEqualStrings("css/style.css", static_mod.sanitizePath(&buf, "css/style.css").?);
    try testing.expectEqualStrings("a/b/c.txt", static_mod.sanitizePath(&buf, "a/b/c.txt").?);
}

test "sanitizePath rejects traversal" {
    var buf: [256]u8 = undefined;
    try testing.expect(static_mod.sanitizePath(&buf, "../etc/passwd") == null);
    try testing.expect(static_mod.sanitizePath(&buf, "../../secret") == null);
}

test "sanitizePath allows safe relative paths" {
    var buf: [256]u8 = undefined;
    // Going up then back down within the root is fine
    try testing.expectEqualStrings("b.txt", static_mod.sanitizePath(&buf, "a/../b.txt").?);
}

test "sanitizePath rejects absolute paths" {
    var buf: [256]u8 = undefined;
    try testing.expect(static_mod.sanitizePath(&buf, "/etc/passwd") == null);
}

test "sanitizePath skips double slashes and dots" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("a/b.txt", static_mod.sanitizePath(&buf, "a//./b.txt").?);
}

test "sanitizePath rejects empty result" {
    var buf: [256]u8 = undefined;
    try testing.expect(static_mod.sanitizePath(&buf, "") == null);
    try testing.expect(static_mod.sanitizePath(&buf, ".") == null);
    try testing.expect(static_mod.sanitizePath(&buf, "./") == null);
}

test "sanitizePath rejects null bytes" {
    var buf: [256]u8 = undefined;
    try testing.expect(static_mod.sanitizePath(&buf, "file\x00.txt") == null);
}

// ── Router static dir integration tests ─────────────────────────────
// These tests use /tmp/blitz-test-static/ as a scratch directory since
// testing.tmpDir() may not be available in all sandbox environments.

const test_static_root = "/tmp/blitz-test-static";

fn setupTestStaticDir() bool {
    // Create test directory structure
    const dir = std.fs.openDirAbsolute("/tmp", .{}) catch return false;
    _ = dir;
    std.fs.makeDirAbsolute(test_static_root) catch |e| {
        if (e != error.PathAlreadyExists) return false;
    };
    std.fs.makeDirAbsolute(test_static_root ++ "/css") catch |e| {
        if (e != error.PathAlreadyExists) return false;
    };

    // Write test files using cwd().writeFile
    const d = std.fs.openDirAbsolute(test_static_root, .{}) catch return false;
    d.writeFile(.{ .sub_path = "index.html", .data = "<h1>Hello Static</h1>" }) catch return false;
    d.writeFile(.{ .sub_path = "app.js", .data = "console.log('hi');" }) catch return false;
    d.writeFile(.{ .sub_path = "test.txt", .data = "hello" }) catch return false;

    const css_dir = std.fs.openDirAbsolute(test_static_root ++ "/css", .{}) catch return false;
    css_dir.writeFile(.{ .sub_path = "style.css", .data = "body { color: red; }" }) catch return false;

    return true;
}

test "Router staticDir serves files from disk" {
    if (!setupTestStaticDir()) return; // skip if can't create files

    var router = Router.init(std.heap.page_allocator);
    router.staticDir("/static", test_static_root, .{});

    // Test serving index.html
    var req = Request{
        .method = .GET,
        .path = "/static/index.html",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    router.handle(&req, &res);
    try testing.expectEqual(StatusCode.ok, res.status);
    try testing.expectEqualStrings("<h1>Hello Static</h1>", res.body.?);
    try testing.expectEqualStrings("text/html; charset=utf-8", res.headers.get("Content-Type").?);

    // Test serving CSS file in subdirectory
    var req2 = Request{
        .method = .GET,
        .path = "/static/css/style.css",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res2 = Response{};
    router.handle(&req2, &res2);
    try testing.expectEqual(StatusCode.ok, res2.status);
    try testing.expectEqualStrings("body { color: red; }", res2.body.?);
    try testing.expectEqualStrings("text/css; charset=utf-8", res2.headers.get("Content-Type").?);
}

test "Router staticDir returns 404 for missing files" {
    if (!setupTestStaticDir()) return;

    var router = Router.init(std.heap.page_allocator);
    router.staticDir("/files", test_static_root, .{});

    var req = Request{
        .method = .GET,
        .path = "/files/nonexistent.txt",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    router.handle(&req, &res);
    try testing.expectEqual(StatusCode.not_found, res.status);
}

test "Router staticDir blocks path traversal" {
    if (!setupTestStaticDir()) return;

    var router = Router.init(std.heap.page_allocator);
    router.staticDir("/static", test_static_root, .{});

    var req = Request{
        .method = .GET,
        .path = "/static/../../../etc/passwd",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    router.handle(&req, &res);
    try testing.expectEqual(StatusCode.not_found, res.status);
}

test "Router staticDir only serves GET and HEAD" {
    if (!setupTestStaticDir()) return;

    var router = Router.init(std.heap.page_allocator);
    router.staticDir("/files", test_static_root, .{});

    // POST should not serve static files
    var req = Request{
        .method = .POST,
        .path = "/files/test.txt",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    router.handle(&req, &res);
    try testing.expectEqual(StatusCode.not_found, res.status);
}

// ════════════════════════════════════════════════════════════════════
// Query string parser tests
// ════════════════════════════════════════════════════════════════════

const Query = query_mod.Query;

test "Query.parse basic key=value pairs" {
    const q = Query.parse("name=Alice&age=30&city=NYC");
    try testing.expectEqual(@as(usize, 3), q.len);
    try testing.expectEqualStrings("Alice", q.get("name").?);
    try testing.expectEqualStrings("30", q.get("age").?);
    try testing.expectEqualStrings("NYC", q.get("city").?);
    try testing.expect(q.get("missing") == null);
}

test "Query.parse empty string" {
    const q = Query.parse("");
    try testing.expectEqual(@as(usize, 0), q.len);
}

test "Query.parse key without value" {
    const q = Query.parse("debug&verbose&name=Bob");
    try testing.expectEqual(@as(usize, 3), q.len);
    try testing.expectEqualStrings("", q.get("debug").?);
    try testing.expectEqualStrings("Bob", q.get("name").?);
    try testing.expect(q.has("debug"));
    try testing.expect(q.has("verbose"));
}

test "Query.parse empty values" {
    const q = Query.parse("key=&other=val");
    try testing.expectEqualStrings("", q.get("key").?);
    try testing.expectEqualStrings("val", q.get("other").?);
}

test "Query.parse value with equals sign" {
    const q = Query.parse("expr=a=b&x=1");
    // Value should be "a=b" — only split on first '='
    // Actually our parser splits on first '=', so value is everything after
    try testing.expectEqualStrings("a=b", q.get("expr").?);
}

test "Query.parse skips empty pairs" {
    const q = Query.parse("a=1&&b=2&");
    try testing.expectEqual(@as(usize, 2), q.len);
    try testing.expectEqualStrings("1", q.get("a").?);
    try testing.expectEqualStrings("2", q.get("b").?);
}

test "Query.getInt returns typed integer" {
    const q = Query.parse("page=5&limit=100&bad=abc");
    try testing.expectEqual(@as(?i64, 5), q.getInt("page", i64));
    try testing.expectEqual(@as(?i64, 100), q.getInt("limit", i64));
    try testing.expect(q.getInt("bad", i64) == null);
    try testing.expect(q.getInt("missing", i64) == null);
}

test "Query.getInt with u32" {
    const q = Query.parse("port=8080");
    try testing.expectEqual(@as(?u32, 8080), q.getInt("port", u32));
}

test "Query.getBool parses boolean values" {
    const q = Query.parse("a=true&b=false&c=1&d=0&e=yes&f=no&g=maybe");
    try testing.expectEqual(@as(?bool, true), q.getBool("a"));
    try testing.expectEqual(@as(?bool, false), q.getBool("b"));
    try testing.expectEqual(@as(?bool, true), q.getBool("c"));
    try testing.expectEqual(@as(?bool, false), q.getBool("d"));
    try testing.expectEqual(@as(?bool, true), q.getBool("e"));
    try testing.expectEqual(@as(?bool, false), q.getBool("f"));
    try testing.expect(q.getBool("g") == null); // "maybe" is not a bool
    try testing.expect(q.getBool("missing") == null);
}

test "Query.has checks key existence" {
    const q = Query.parse("flag&name=Bob");
    try testing.expect(q.has("flag"));
    try testing.expect(q.has("name"));
    try testing.expect(!q.has("missing"));
}

test "Query.getAll returns multiple values" {
    const q = Query.parse("tag=zig&tag=http&tag=fast&name=blitz");
    var vals: [4][]const u8 = undefined;
    const n = q.getAll("tag", &vals);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("zig", vals[0]);
    try testing.expectEqualStrings("http", vals[1]);
    try testing.expectEqualStrings("fast", vals[2]);
}

test "Query.iterator iterates all params" {
    const q = Query.parse("a=1&b=2&c=3");
    var it = q.iterator();
    const p1 = it.next().?;
    try testing.expectEqualStrings("a", p1.key);
    try testing.expectEqualStrings("1", p1.value);
    const p2 = it.next().?;
    try testing.expectEqualStrings("b", p2.key);
    const p3 = it.next().?;
    try testing.expectEqualStrings("c", p3.key);
    try testing.expect(it.next() == null);
}

test "Query.count returns param count" {
    const q = Query.parse("a=1&b=2&c=3");
    try testing.expectEqual(@as(usize, 3), q.paramCount());
}

test "Query.getDecode decodes URL-encoded value" {
    const q = Query.parse("name=hello%20world&path=a%2Fb");
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("hello world", q.getDecode("name", &buf).?);
    try testing.expectEqualStrings("a/b", q.getDecode("path", &buf).?);
    try testing.expect(q.getDecode("missing", &buf) == null);
}

// ── URL decoding tests ──────────────────────────────────────────────

test "urlDecode plain string" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("hello", query_mod.urlDecode(&buf, "hello").?);
}

test "urlDecode plus as space" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("hello world", query_mod.urlDecode(&buf, "hello+world").?);
}

test "urlDecode percent encoding" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("hello world", query_mod.urlDecode(&buf, "hello%20world").?);
    try testing.expectEqualStrings("/path/to", query_mod.urlDecode(&buf, "%2Fpath%2Fto").?);
    try testing.expectEqualStrings("a&b=c", query_mod.urlDecode(&buf, "a%26b%3Dc").?);
}

test "urlDecode mixed encoding" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("foo bar&baz", query_mod.urlDecode(&buf, "foo+bar%26baz").?);
}

test "urlDecode uppercase hex" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(" ", query_mod.urlDecode(&buf, "%20").?);
    try testing.expectEqualStrings(" ", query_mod.urlDecode(&buf, "%20").?);
}

test "urlDecode lowercase hex" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/", query_mod.urlDecode(&buf, "%2f").?);
}

test "urlDecode truncated percent returns null" {
    var buf: [256]u8 = undefined;
    try testing.expect(query_mod.urlDecode(&buf, "abc%2") == null);
    try testing.expect(query_mod.urlDecode(&buf, "abc%") == null);
}

test "urlDecode invalid hex returns null" {
    var buf: [256]u8 = undefined;
    try testing.expect(query_mod.urlDecode(&buf, "%GG") == null);
    try testing.expect(query_mod.urlDecode(&buf, "%ZZ") == null);
}

test "urlDecode buffer overflow returns null" {
    var buf: [3]u8 = undefined;
    try testing.expect(query_mod.urlDecode(&buf, "abcd") == null);
    try testing.expectEqualStrings("abc", query_mod.urlDecode(&buf, "abc").?);
}

test "urlDecode empty string" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("", query_mod.urlDecode(&buf, "").?);
}

// ── Request.queryParsed integration test ────────────────────────────

test "Request.queryParsed returns structured Query" {
    const req = Request{
        .method = .GET,
        .path = "/search",
        .query = "q=hello+world&page=2&debug",
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    const q = req.queryParsed();
    try testing.expectEqual(@as(usize, 3), q.paramCount());
    try testing.expectEqualStrings("hello+world", q.get("q").?);
    try testing.expectEqual(@as(?i64, 2), q.getInt("page", i64));
    try testing.expect(q.has("debug"));

    // URL-decode the query param
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("hello world", q.getDecode("q", &buf).?);
}

test "Request.queryParsed with no query returns empty" {
    const req = Request{
        .method = .GET,
        .path = "/",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    const q = req.queryParsed();
    try testing.expectEqual(@as(usize, 0), q.paramCount());
}

// ════════════════════════════════════════════════════════════════════
// Connection pool tests
// ════════════════════════════════════════════════════════════════════

const ConnPool = pool_mod.ConnPool;

test "ConnPool acquire and release" {
    var pool = try ConnPool.init(testing.allocator, 4);
    defer pool.deinit();

    const s1 = pool.acquire().?;
    const s2 = pool.acquire().?;
    try testing.expect(s1 != s2);
    try testing.expectEqual(@as(usize, 2), pool.pool_hits);

    pool.release(s1);
    pool.release(s2);

    // Re-acquire should get pooled objects back
    const s3 = pool.acquire().?;
    try testing.expect(s3 == s2 or s3 == s1); // LIFO — should get s2 back
    pool.release(s3);
}

test "ConnPool exhaustion and fallback" {
    var pool = try ConnPool.init(testing.allocator, 2);
    defer pool.deinit();

    const s1 = pool.acquire().?;
    const s2 = pool.acquire().?;
    // Pool is exhausted, next acquire falls back to heap
    const s3 = pool.acquire().?;
    try testing.expectEqual(@as(usize, 2), pool.pool_hits);
    try testing.expectEqual(@as(usize, 1), pool.fallback_allocs);
    try testing.expectEqual(std.math.maxInt(u32), s3.pool_index); // sentinel

    // Release heap-allocated (should free it)
    pool.release(s3);
    pool.release(s2);
    pool.release(s1);
}

test "ConnPool reset clears state" {
    var pool = try ConnPool.init(testing.allocator, 2);
    defer pool.deinit();

    const s = pool.acquire().?;
    s.read_len = 42;
    try s.write_list.appendSlice("test data");
    s.write_off = 5;

    pool.release(s);
    const s2 = pool.acquire().?;
    try testing.expect(s == s2); // same slot
    try testing.expectEqual(@as(usize, 0), s2.read_len);
    try testing.expectEqual(@as(usize, 0), s2.write_off);
    // write_list capacity retained but items cleared
    try testing.expectEqual(@as(usize, 0), s2.write_list.items.len);
    pool.release(s2);
}

test "ConnPool full cycle" {
    var pool = try ConnPool.init(testing.allocator, 3);
    defer pool.deinit();

    // Acquire all 3
    var slots: [3]*pool_mod.ConnState = undefined;
    for (0..3) |i| {
        slots[i] = pool.acquire().?;
    }
    try testing.expectEqual(@as(usize, 0), pool.free_top);

    // Release all
    for (0..3) |i| {
        pool.release(slots[i]);
    }
    try testing.expectEqual(@as(usize, 3), pool.free_top);

    // Acquire again — all from pool
    for (0..3) |i| {
        slots[i] = pool.acquire().?;
    }
    try testing.expectEqual(@as(usize, 6), pool.pool_hits); // 3 + 3
    for (0..3) |i| {
        pool.release(slots[i]);
    }
}

// ════════════════════════════════════════════════════════════════════
// Per-route middleware tests
// ════════════════════════════════════════════════════════════════════

test "Per-route middleware runs for matching routes" {
    var router = Router.init(std.heap.page_allocator);

    // Attach middleware to /api prefix
    router.useAt("/api", struct {
        fn f(_: *Request, res: *Response) bool {
            res.headers.set("X-Api-Auth", "checked");
            return true;
        }
    }.f);

    router.get("/api/users", dummyHandler);
    router.get("/public/page", dummyHandler);

    // Request to /api/users should run the middleware
    var req = Request{
        .method = .GET,
        .path = "/api/users",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    router.handle(&req, &res);
    try testing.expectEqualStrings("ok", res.body.?);
    try testing.expectEqualStrings("checked", res.headers.get("X-Api-Auth").?);

    // Request to /public/page should NOT have the middleware header
    var req2 = Request{
        .method = .GET,
        .path = "/public/page",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res2 = Response{};
    router.handle(&req2, &res2);
    try testing.expectEqualStrings("ok", res2.body.?);
    try testing.expect(res2.headers.get("X-Api-Auth") == null);
}

test "Per-route middleware can short-circuit" {
    var router = Router.init(std.heap.page_allocator);

    router.useAt("/admin", struct {
        fn f(_: *Request, res: *Response) bool {
            _ = res.setStatus(.forbidden).text("admin only");
            return false;
        }
    }.f);

    router.get("/admin/dashboard", struct {
        fn f(_: *Request, res: *Response) void {
            _ = res.text("secret dashboard");
        }
    }.f);

    var req = Request{
        .method = .GET,
        .path = "/admin/dashboard",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    router.handle(&req, &res);
    try testing.expectEqual(StatusCode.forbidden, res.status);
    try testing.expectEqualStrings("admin only", res.body.?);
}

test "Per-route middleware inherits through nested paths" {
    var router = Router.init(std.heap.page_allocator);

    // Middleware on /api — should apply to /api/v1/users too
    router.useAt("/api", struct {
        fn f(_: *Request, res: *Response) bool {
            res.headers.set("X-Api", "true");
            return true;
        }
    }.f);

    router.get("/api/v1/users", dummyHandler);

    var req = Request{
        .method = .GET,
        .path = "/api/v1/users",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    router.handle(&req, &res);
    try testing.expectEqualStrings("ok", res.body.?);
    try testing.expectEqualStrings("true", res.headers.get("X-Api").?);
}

test "Per-route middleware stacks with global middleware" {
    var router = Router.init(std.heap.page_allocator);

    // Global middleware
    router.use(struct {
        fn f(_: *Request, res: *Response) bool {
            res.headers.set("X-Global", "yes");
            return true;
        }
    }.f);

    // Route-level middleware
    router.useAt("/api", struct {
        fn f(_: *Request, res: *Response) bool {
            res.headers.set("X-Route", "yes");
            return true;
        }
    }.f);

    router.get("/api/test", dummyHandler);

    var req = Request{
        .method = .GET,
        .path = "/api/test",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    router.handle(&req, &res);
    try testing.expectEqualStrings("yes", res.headers.get("X-Global").?);
    try testing.expectEqualStrings("yes", res.headers.get("X-Route").?);
}

test "Multiple per-route middleware run in order" {
    var router = Router.init(std.heap.page_allocator);

    router.useAt("/api", struct {
        fn f(_: *Request, res: *Response) bool {
            res.headers.set("X-Order", "first");
            return true;
        }
    }.f);

    router.useAt("/api", struct {
        fn f(_: *Request, res: *Response) bool {
            res.headers.set("X-Order", "second");
            return true;
        }
    }.f);

    router.get("/api/test", dummyHandler);

    var req = Request{
        .method = .GET,
        .path = "/api/test",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    router.handle(&req, &res);
    try testing.expectEqualStrings("second", res.headers.get("X-Order").?);
}

test "Group.use attaches middleware to group prefix" {
    var router = Router.init(std.heap.page_allocator);

    const api = router.group("/api");
    api.use(struct {
        fn f(_: *Request, res: *Response) bool {
            res.headers.set("X-Group-MW", "api");
            return true;
        }
    }.f);

    api.get("/items", dummyHandler);
    router.get("/other", dummyHandler);

    // Route under group should have middleware
    var req = Request{
        .method = .GET,
        .path = "/api/items",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    router.handle(&req, &res);
    try testing.expectEqualStrings("api", res.headers.get("X-Group-MW").?);

    // Route outside group should not
    var req2 = Request{
        .method = .GET,
        .path = "/other",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res2 = Response{};
    router.handle(&req2, &res2);
    try testing.expect(res2.headers.get("X-Group-MW") == null);
}

test "Nested group middleware stacks" {
    var router = Router.init(std.heap.page_allocator);

    const api = router.group("/api");
    api.use(struct {
        fn f(_: *Request, res: *Response) bool {
            res.headers.set("X-Api", "yes");
            return true;
        }
    }.f);

    const admin = api.group("/admin");
    admin.use(struct {
        fn f(_: *Request, res: *Response) bool {
            res.headers.set("X-Admin", "yes");
            return true;
        }
    }.f);

    admin.get("/stats", dummyHandler);

    var req = Request{
        .method = .GET,
        .path = "/api/admin/stats",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    router.handle(&req, &res);
    try testing.expectEqualStrings("yes", res.headers.get("X-Api").?);
    try testing.expectEqualStrings("yes", res.headers.get("X-Admin").?);
}

test "Per-route middleware with path params" {
    var router = Router.init(std.heap.page_allocator);

    router.useAt("/users", struct {
        fn f(_: *Request, res: *Response) bool {
            res.headers.set("X-Users-MW", "applied");
            return true;
        }
    }.f);

    router.get("/users/:id", userHandler);

    var req = Request{
        .method = .GET,
        .path = "/users/42",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    router.handle(&req, &res);
    try testing.expectEqualStrings("42", res.body.?);
    try testing.expectEqualStrings("applied", res.headers.get("X-Users-MW").?);
}

// ════════════════════════════════════════════════════════════════════
// Body parser tests
// ════════════════════════════════════════════════════════════════════

test "parseForm basic URL-encoded body" {
    const form = body_mod.parseForm("name=Alice&age=30&city=NYC");
    try testing.expectEqual(@as(usize, 3), form.len);
    try testing.expectEqualStrings("Alice", form.get("name").?);
    try testing.expectEqualStrings("30", form.get("age").?);
    try testing.expectEqual(@as(?i64, 30), form.getInt("age", i64));
}

test "parseForm empty body" {
    const form = body_mod.parseForm("");
    try testing.expectEqual(@as(usize, 0), form.len);
}

test "parseForm URL-encoded with special chars" {
    const form = body_mod.parseForm("msg=hello+world&path=%2Fhome");
    try testing.expectEqualStrings("hello+world", form.get("msg").?);
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("hello world", form.getDecode("msg", &buf).?);
    try testing.expectEqualStrings("/home", form.getDecode("path", &buf).?);
}

test "detectContentType identifies form types" {
    try testing.expectEqual(body_mod.ContentType.form_urlencoded, body_mod.detectContentType("application/x-www-form-urlencoded"));
    try testing.expectEqual(body_mod.ContentType.multipart, body_mod.detectContentType("multipart/form-data; boundary=abc"));
    try testing.expectEqual(body_mod.ContentType.json, body_mod.detectContentType("application/json"));
    try testing.expectEqual(body_mod.ContentType.json, body_mod.detectContentType("application/json; charset=utf-8"));
    try testing.expectEqual(body_mod.ContentType.text, body_mod.detectContentType("text/plain"));
    try testing.expectEqual(body_mod.ContentType.unknown, body_mod.detectContentType(""));
    try testing.expectEqual(body_mod.ContentType.unknown, body_mod.detectContentType("image/png"));
}

test "detectContentType case insensitive" {
    try testing.expectEqual(body_mod.ContentType.json, body_mod.detectContentType("Application/JSON"));
    try testing.expectEqual(body_mod.ContentType.form_urlencoded, body_mod.detectContentType("APPLICATION/X-WWW-FORM-URLENCODED"));
}

test "extractBoundary from Content-Type" {
    try testing.expectEqualStrings(
        "----WebKitFormBoundary",
        body_mod.extractBoundary("multipart/form-data; boundary=----WebKitFormBoundary").?,
    );
    try testing.expectEqualStrings(
        "abc123",
        body_mod.extractBoundary("multipart/form-data; boundary=\"abc123\"").?,
    );
    try testing.expect(body_mod.extractBoundary("application/json") == null);
}

test "parseMultipart simple form" {
    const boundary = "----formdata";
    const body =
        "------formdata\r\n" ++
        "Content-Disposition: form-data; name=\"username\"\r\n" ++
        "\r\n" ++
        "Alice\r\n" ++
        "------formdata\r\n" ++
        "Content-Disposition: form-data; name=\"email\"\r\n" ++
        "\r\n" ++
        "alice@example.com\r\n" ++
        "------formdata--\r\n";

    const result = body_mod.parseMultipart(body, boundary);
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqualStrings("username", result.parts[0].name);
    try testing.expectEqualStrings("Alice", result.parts[0].data);
    try testing.expectEqualStrings("email", result.parts[1].name);
    try testing.expectEqualStrings("alice@example.com", result.parts[1].data);
}

test "parseMultipart with file" {
    const boundary = "----formdata";
    const body =
        "------formdata\r\n" ++
        "Content-Disposition: form-data; name=\"file\"; filename=\"test.txt\"\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "file contents here\r\n" ++
        "------formdata--\r\n";

    const result = body_mod.parseMultipart(body, boundary);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("file", result.parts[0].name);
    try testing.expectEqualStrings("test.txt", result.parts[0].filename.?);
    try testing.expectEqualStrings("text/plain", result.parts[0].content_type);
    try testing.expectEqualStrings("file contents here", result.parts[0].data);
}

test "parseMultipart get and getFile" {
    const boundary = "----formdata";
    const body =
        "------formdata\r\n" ++
        "Content-Disposition: form-data; name=\"title\"\r\n" ++
        "\r\n" ++
        "My Upload\r\n" ++
        "------formdata\r\n" ++
        "Content-Disposition: form-data; name=\"doc\"; filename=\"doc.pdf\"\r\n" ++
        "Content-Type: application/pdf\r\n" ++
        "\r\n" ++
        "PDF DATA\r\n" ++
        "------formdata--\r\n";

    const result = body_mod.parseMultipart(body, boundary);
    try testing.expectEqual(@as(usize, 2), result.len);

    const title = result.get("title").?;
    try testing.expectEqualStrings("My Upload", title.data);
    try testing.expect(title.filename == null);

    const doc = result.getFile("doc").?;
    try testing.expectEqualStrings("doc.pdf", doc.filename.?);
    try testing.expectEqualStrings("PDF DATA", doc.data);

    // getFile should not return non-file parts
    try testing.expect(result.getFile("title") == null);
}

test "Request.formData parses body as form" {
    const req = Request{
        .method = .POST,
        .path = "/submit",
        .query = null,
        .headers = .{},
        .body = "name=Bob&role=admin",
        .raw_header = "",
    };
    const form = req.formData();
    try testing.expectEqualStrings("Bob", form.get("name").?);
    try testing.expectEqualStrings("admin", form.get("role").?);
}

test "Request.formData with no body returns empty" {
    const req = Request{
        .method = .POST,
        .path = "/submit",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    const form = req.formData();
    try testing.expectEqual(@as(usize, 0), form.paramCount());
}

test "Request.contentType detects from header" {
    var req = Request{
        .method = .POST,
        .path = "/submit",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    req.headers.set("Content-Type", "application/json");
    try testing.expectEqual(body_mod.ContentType.json, req.contentType());
}

test "Router staticDir with cache control" {
    if (!setupTestStaticDir()) return;

    var router = Router.init(std.heap.page_allocator);
    router.staticDir("/assets", test_static_root, .{ .cache_control = "public, max-age=31536000" });

    var req = Request{
        .method = .GET,
        .path = "/assets/app.js",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    router.handle(&req, &res);
    try testing.expectEqual(StatusCode.ok, res.status);
    try testing.expectEqualStrings("public, max-age=31536000", res.headers.get("Cache-Control").?);
}

// ════════════════════════════════════════════════════════════════════
// Cookie parsing tests
// ════════════════════════════════════════════════════════════════════

test "parseCookies single cookie" {
    const jar = cookie_mod.parseCookies("session=abc123");
    try testing.expectEqual(@as(usize, 1), jar.len);
    try testing.expectEqualStrings("abc123", jar.get("session").?);
}

test "parseCookies multiple cookies" {
    const jar = cookie_mod.parseCookies("session=abc123; theme=dark; lang=en");
    try testing.expectEqual(@as(usize, 3), jar.len);
    try testing.expectEqualStrings("abc123", jar.get("session").?);
    try testing.expectEqualStrings("dark", jar.get("theme").?);
    try testing.expectEqualStrings("en", jar.get("lang").?);
}

test "parseCookies with spaces" {
    const jar = cookie_mod.parseCookies("  a=1;  b=2  ;c=3");
    try testing.expectEqual(@as(usize, 3), jar.len);
    try testing.expectEqualStrings("1", jar.get("a").?);
    try testing.expectEqualStrings("2", jar.get("b").?);
    try testing.expectEqualStrings("3", jar.get("c").?);
}

test "parseCookies empty value" {
    const jar = cookie_mod.parseCookies("token=; name=Bob");
    try testing.expectEqual(@as(usize, 2), jar.len);
    try testing.expectEqualStrings("", jar.get("token").?);
    try testing.expectEqualStrings("Bob", jar.get("name").?);
}

test "parseCookies no equals sign skipped" {
    const jar = cookie_mod.parseCookies("valid=yes; malformed; also=ok");
    try testing.expectEqual(@as(usize, 2), jar.len);
    try testing.expectEqualStrings("yes", jar.get("valid").?);
    try testing.expectEqualStrings("ok", jar.get("also").?);
}

test "parseCookies has() method" {
    const jar = cookie_mod.parseCookies("a=1; b=2");
    try testing.expect(jar.has("a"));
    try testing.expect(jar.has("b"));
    try testing.expect(!jar.has("c"));
}

test "parseCookies iterator" {
    const jar = cookie_mod.parseCookies("x=1; y=2; z=3");
    var it = jar.iterator();
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 3), count);
}

test "parseCookies empty string" {
    const jar = cookie_mod.parseCookies("");
    try testing.expectEqual(@as(usize, 0), jar.len);
}

test "parseCookies value with equals sign" {
    // Cookie values can contain = (e.g., base64 encoded)
    const jar = cookie_mod.parseCookies("token=abc=def==");
    try testing.expectEqual(@as(usize, 1), jar.len);
    try testing.expectEqualStrings("abc=def==", jar.get("token").?);
}

// ════════════════════════════════════════════════════════════════════
// Set-Cookie builder tests
// ════════════════════════════════════════════════════════════════════

test "buildSetCookie basic" {
    var buf: [256]u8 = undefined;
    const result = cookie_mod.buildSetCookie(&buf, "session", "abc123", .{});
    try testing.expect(result != null);
    try testing.expectEqualStrings("session=abc123", result.?);
}

test "buildSetCookie with all options" {
    var buf: [256]u8 = undefined;
    const result = cookie_mod.buildSetCookie(&buf, "id", "42", .{
        .max_age = 3600,
        .path = "/",
        .domain = "example.com",
        .secure = true,
        .http_only = true,
        .same_site = .strict,
    });
    try testing.expect(result != null);
    const s = result.?;
    try testing.expect(mem.indexOf(u8, s, "id=42") != null);
    try testing.expect(mem.indexOf(u8, s, "Max-Age=3600") != null);
    try testing.expect(mem.indexOf(u8, s, "Path=/") != null);
    try testing.expect(mem.indexOf(u8, s, "Domain=example.com") != null);
    try testing.expect(mem.indexOf(u8, s, "Secure") != null);
    try testing.expect(mem.indexOf(u8, s, "HttpOnly") != null);
    try testing.expect(mem.indexOf(u8, s, "SameSite=Strict") != null);
}

test "buildSetCookie buffer too small" {
    var buf: [5]u8 = undefined;
    const result = cookie_mod.buildSetCookie(&buf, "session", "abc123", .{});
    try testing.expect(result == null);
}

test "buildDeleteCookie sets Max-Age=0" {
    var buf: [256]u8 = undefined;
    const result = cookie_mod.buildDeleteCookie(&buf, "session", .{ .path = "/" });
    try testing.expect(result != null);
    const s = result.?;
    try testing.expect(mem.indexOf(u8, s, "session=") != null);
    try testing.expect(mem.indexOf(u8, s, "Max-Age=0") != null);
    try testing.expect(mem.indexOf(u8, s, "Path=/") != null);
}

test "buildSetCookie SameSite variants" {
    var buf: [256]u8 = undefined;
    const lax = cookie_mod.buildSetCookie(&buf, "a", "1", .{ .same_site = .lax }).?;
    try testing.expect(mem.indexOf(u8, lax, "SameSite=Lax") != null);

    const none = cookie_mod.buildSetCookie(&buf, "a", "1", .{ .same_site = .none }).?;
    try testing.expect(mem.indexOf(u8, none, "SameSite=None") != null);
}

// ════════════════════════════════════════════════════════════════════
// Request cookie integration tests
// ════════════════════════════════════════════════════════════════════

test "Request.cookies() parses Cookie header" {
    var req = Request{
        .method = .GET,
        .path = "/",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    req.headers.set("Cookie", "session=abc; theme=dark");

    const jar = req.cookies();
    try testing.expectEqual(@as(usize, 2), jar.len);
    try testing.expectEqualStrings("abc", jar.get("session").?);
    try testing.expectEqualStrings("dark", jar.get("theme").?);
}

test "Request.cookie() convenience method" {
    var req = Request{
        .method = .GET,
        .path = "/",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    req.headers.set("Cookie", "token=xyz789");

    try testing.expectEqualStrings("xyz789", req.cookie("token").?);
    try testing.expect(req.cookie("missing") == null);
}

test "Request.cookies() no Cookie header" {
    const req = Request{
        .method = .GET,
        .path = "/",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    const jar = req.cookies();
    try testing.expectEqual(@as(usize, 0), jar.len);
}

// ════════════════════════════════════════════════════════════════════
// Response cookie and redirect tests
// ════════════════════════════════════════════════════════════════════

test "Response.setCookie adds Set-Cookie header" {
    var res = Response{};
    var buf: [256]u8 = undefined;
    _ = res.setCookie(&buf, "session", "abc", .{ .http_only = true, .path = "/" });
    const header = res.headers.get("Set-Cookie").?;
    try testing.expect(mem.indexOf(u8, header, "session=abc") != null);
    try testing.expect(mem.indexOf(u8, header, "HttpOnly") != null);
}

test "Response.deleteCookie adds deletion cookie" {
    var res = Response{};
    var buf: [256]u8 = undefined;
    _ = res.deleteCookie(&buf, "session", .{ .path = "/" });
    const header = res.headers.get("Set-Cookie").?;
    try testing.expect(mem.indexOf(u8, header, "Max-Age=0") != null);
}

test "Response.redirect sets location and status" {
    var res = Response{};
    _ = res.redirect("/login", .found);
    try testing.expectEqual(StatusCode.found, res.status);
    try testing.expectEqualStrings("/login", res.headers.get("Location").?);
    try testing.expectEqualStrings("", res.body.?);
}

test "Response.redirectTemp uses 302" {
    var res = Response{};
    _ = res.redirectTemp("/home");
    try testing.expectEqual(StatusCode.found, res.status);
    try testing.expectEqualStrings("/home", res.headers.get("Location").?);
}

test "Response.redirectPerm uses 301" {
    var res = Response{};
    _ = res.redirectPerm("/new-url");
    try testing.expectEqual(StatusCode.moved_permanently, res.status);
    try testing.expectEqualStrings("/new-url", res.headers.get("Location").?);
}

// ════════════════════════════════════════════════════════════════════
// ConnState keep-alive tests
// ════════════════════════════════════════════════════════════════════

test "ConnState.touch updates last_active" {
    var st = pool_mod.ConnState.init(std.heap.page_allocator);
    defer st.deinit();
    try testing.expectEqual(@as(i64, 0), st.last_active);
    st.touch();
    try testing.expect(st.last_active > 0);
}

test "ConnState.reset clears fd and last_active" {
    var st = pool_mod.ConnState.init(std.heap.page_allocator);
    defer st.deinit();
    st.fd = 42;
    st.touch();
    st.reset();
    try testing.expectEqual(@as(i32, -1), st.fd);
    try testing.expectEqual(@as(i64, 0), st.last_active);
}
