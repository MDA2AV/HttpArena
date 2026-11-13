const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = @import("anole").addApp(b, .{
        .name = "anole-arena",
        .root_source_file = b.path("src/main.zig"),
        .protos = &.{.{ .name = "benchmark_pb", .file = b.path("proto/benchmark.proto") }},
    });
}
