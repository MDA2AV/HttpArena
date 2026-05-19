const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const zeemo_dep = b.dependency("zeemo", .{
        .target = target,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
    });
    exe_mod.addImport("zeemo", zeemo_dep.module("zeemo"));

    const exe = b.addExecutable(.{
        .name = "zeemo-tuned",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);
}
