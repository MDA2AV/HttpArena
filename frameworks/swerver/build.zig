const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize: std.builtin.OptimizeMode = .ReleaseFast;

    const swerver_dep = b.dependency("swerver", .{
        .target = target,
        .optimize = optimize,
        .@"enable-tls" = true,
        .@"enable-http2" = true,
        .@"enable-http3" = true,
    });

    const exe_module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_module.addImport("swerver", swerver_dep.module("swerver"));

    const exe = b.addExecutable(.{
        .name = "swerver-httparena",
        .root_module = exe_module,
    });
    b.installArtifact(exe);
}
