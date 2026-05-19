//! zeemo — bare-metal Zig HTTP/1.1 server built directly on `io_uring`.
//!
//! Public API:
//!
//! ```zig
//! const zeemo = @import("zeemo");
//!
//! pub fn main() !void {
//!     var gpa: std.heap.smp_allocator = .{};
//!     var server = zeemo.Server.init(gpa.allocator(), .{ .port = 8080 });
//!     defer server.deinit();
//!     try server.get("/hello", helloHandler);
//!     try server.run();
//! }
//!
//! fn helloHandler(_: *const zeemo.Request, res: *zeemo.Response) !void {
//!     try res.text("Hello, World!");
//! }
//! ```

pub const Server = @import("server.zig").Server;
pub const Config = @import("server.zig").Config;
pub const Request = @import("request.zig").Request;
pub const Response = @import("response.zig").Response;
pub const ContentType = @import("response.zig").ContentType;
pub const Method = @import("http.zig").Method;
pub const HandlerFn = @import("router.zig").HandlerFn;
pub const Params = @import("router.zig").Params;
pub const json = @import("json.zig");
pub const static = @import("static.zig");
