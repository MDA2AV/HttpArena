const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const xev = b.dependency("libxev", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("xev", xev.module("xev"));
    exe.root_module.addIncludePath(b.path("third_party/picohttpparser"));
    exe.root_module.addCSourceFile(.{ .file = b.path("third_party/picohttpparser/picohttpparser.c"), .flags = &.{"-O3"} });
    exe.root_module.link_libc = true;
    b.installArtifact(exe);
}
