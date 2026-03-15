//! # blitz ⚡
//!
//! A blazing-fast HTTP/1.1 micro web framework for Zig.
//!
//! Built on epoll with SO_REUSEPORT multi-threading, zero-copy parsing,
//! and a radix-trie router with path parameters.
//!
//! ## Quick Start
//!
//! ```zig
//! const blitz = @import("blitz");
//!
//! fn hello(_: *blitz.Request, res: *blitz.Response) void {
//!     _ = res.text("Hello, World!");
//! }
//!
//! fn greet(req: *blitz.Request, res: *blitz.Response) void {
//!     const name = req.params.get("name") orelse "stranger";
//!     // Use name to build response...
//!     _ = res.text(name);
//! }
//!
//! pub fn main() !void {
//!     var router = blitz.Router.init(std.heap.c_allocator);
//!     router.get("/", hello);
//!     router.get("/hello/:name", greet);
//!
//!     var server = blitz.Server.init(&router, .{ .port = 8080 });
//!     try server.listen();
//! }
//! ```

pub const types = @import("blitz/types.zig");
pub const router_mod = @import("blitz/router.zig");
pub const parser_mod = @import("blitz/parser.zig");
pub const server_mod = @import("blitz/server.zig");
pub const json_mod = @import("blitz/json.zig");
pub const errors_mod = @import("blitz/errors.zig");
pub const static_mod = @import("blitz/static.zig");
pub const query_mod = @import("blitz/query.zig");
pub const pool_mod = @import("blitz/pool.zig");
pub const body_mod = @import("blitz/body.zig");
pub const cookie_mod = @import("blitz/cookie.zig");
pub const compress_mod = @import("blitz/compress.zig");
pub const log_mod = @import("blitz/log.zig");
pub const uring_mod = @import("blitz/uring.zig");

// Re-export main types for convenience
pub const Request = types.Request;
pub const Response = types.Response;
pub const Method = types.Method;
pub const StatusCode = types.StatusCode;
pub const Headers = types.Headers;
pub const HandlerFn = types.HandlerFn;
pub const MiddlewareFn = types.MiddlewareFn;
pub const Router = router_mod.Router;
pub const Group = router_mod.Group;
pub const Server = server_mod.Server;
pub const Config = server_mod.Config;

// JSON
pub const Json = json_mod.Json;
pub const JsonObject = json_mod.JsonObject;
pub const JsonArray = json_mod.JsonArray;

// Static file serving
pub const serveFile = static_mod.serveFile;
pub const mimeFromPath = static_mod.mimeFromPath;
pub const mimeFromExt = static_mod.mimeFromExt;
pub const sanitizePath = static_mod.sanitizePath;
pub const StaticDirConfig = static_mod.StaticDirConfig;

// Error handling
pub const sendError = errors_mod.sendError;
pub const badRequest = errors_mod.badRequest;
pub const unauthorized = errors_mod.unauthorized;
pub const forbidden = errors_mod.forbidden;
pub const notFound = errors_mod.notFound;
pub const methodNotAllowed = errors_mod.methodNotAllowed;
pub const internalError = errors_mod.internalError;
pub const jsonNotFoundHandler = errors_mod.jsonNotFoundHandler;
pub const jsonMethodNotAllowedHandler = errors_mod.jsonMethodNotAllowedHandler;

// Query string parsing
pub const Query = query_mod.Query;
pub const urlDecode = query_mod.urlDecode;

// Body parsing
pub const FormData = body_mod.FormData;
pub const parseForm = body_mod.parseForm;
pub const ContentType = body_mod.ContentType;
pub const detectContentType = body_mod.detectContentType;
pub const extractBoundary = body_mod.extractBoundary;
pub const MultipartPart = body_mod.MultipartPart;
pub const MultipartResult = body_mod.MultipartResult;
pub const parseMultipart = body_mod.parseMultipart;

// Connection pooling
pub const ConnPool = pool_mod.ConnPool;
pub const ConnState = pool_mod.ConnState;

// Cookies
pub const CookieJar = cookie_mod.CookieJar;
pub const Cookie = cookie_mod.Cookie;
pub const parseCookies = cookie_mod.parseCookies;
pub const SetCookieOpts = cookie_mod.SetCookieOpts;
pub const SameSite = cookie_mod.SameSite;
pub const buildSetCookie = cookie_mod.buildSetCookie;
pub const buildDeleteCookie = cookie_mod.buildDeleteCookie;

// Compression
pub const Encoding = compress_mod.Encoding;
pub const acceptedEncoding = compress_mod.acceptedEncoding;
pub const shouldCompress = compress_mod.shouldCompress;
pub const compressResponse = compress_mod.compressResponse;
pub const gzipCompressSlice = compress_mod.gzipCompressSlice;
pub const deflateCompressSlice = compress_mod.deflateCompressSlice;

// Logging
pub const LogConfig = log_mod.LogConfig;
pub const LogFormat = log_mod.Format;
pub const LogLevel = log_mod.Level;
pub const logRequest = log_mod.logRequest;
pub const logNow = log_mod.now;
pub const logMsg = log_mod.log;

// io_uring backend
pub const UringServer = uring_mod.UringServer;
pub const UringConfig = uring_mod.Config;

// Graceful shutdown
pub const isShuttingDown = server_mod.isShuttingDown;

// Utilities
pub const writeUsize = types.writeUsize;
pub const writeI64 = types.writeI64;
pub const asciiEqlIgnoreCase = types.asciiEqlIgnoreCase;

// Parser
pub const parse = parser_mod.parse;

// Tests (pulled in by `zig build test`)
test {
    _ = @import("blitz/tests.zig");
    _ = @import("blitz/static.zig");
    _ = @import("blitz/query.zig");
    _ = @import("blitz/pool.zig");
    _ = @import("blitz/body.zig");
    _ = @import("blitz/cookie.zig");
    _ = @import("blitz/compress.zig");
    _ = @import("blitz/log.zig");
}
