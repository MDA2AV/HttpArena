const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const quic = b.dependency("quic", .{ .target = target, .optimize = optimize }).module("quic");
    const http = b.dependency("http", .{ .target = target, .optimize = optimize }).module("http");

    const exe = b.addExecutable(.{
        .name = "netcode-http-arena",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = true,
            .imports = &.{
                .{ .name = "quic", .module = quic },
                .{ .name = "http", .module = http },
            },
        }),
    });
    b.installArtifact(exe);
}
