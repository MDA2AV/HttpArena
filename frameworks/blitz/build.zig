const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Pull blitz as a package dependency
    const blitz_dep = b.dependency("blitz", .{
        .target = target,
        .optimize = optimize,
    });
    const blitz_mod = blitz_dep.module("blitz");

    // HttpArena benchmark server
    const exe = b.addExecutable(.{
        .name = "blitz",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = false,
    });
    exe.root_module.addImport("blitz", blitz_mod);
    exe.linkLibC();
    exe.linkSystemLibrary("sqlite3");
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the server");
    run_step.dependOn(&run_cmd.step);
}
