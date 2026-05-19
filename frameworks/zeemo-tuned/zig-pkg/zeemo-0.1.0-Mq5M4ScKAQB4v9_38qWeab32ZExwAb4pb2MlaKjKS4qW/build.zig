const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    // Public library module — what downstream code imports as @import("zeemo").
    const zeemo_mod = b.addModule("zeemo", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Hello-world example exe.
    const hello_mod = b.createModule(.{
        .root_source_file = b.path("examples/hello_world/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
    });
    hello_mod.addImport("zeemo", zeemo_mod);
    const hello = b.addExecutable(.{
        .name = "hello",
        .root_module = hello_mod,
    });
    b.installArtifact(hello);

    // HttpArena tuned-category entry. Uses the zeemo lib through its
    // public API exactly like an external project would — once we publish
    // and the standalone `frameworks/zeemo-tuned/` PR fetches zeemo via
    // `zig fetch --save`, the consumer side will look identical.
    const tuned_mod = b.createModule(.{
        .root_source_file = b.path("examples/httparena-tuned/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
    });
    tuned_mod.addImport("zeemo", zeemo_mod);
    const tuned_exe = b.addExecutable(.{
        .name = "zeemo-tuned",
        .root_module = tuned_mod,
    });
    b.installArtifact(tuned_exe);

    // Library unit tests — run via `zig build test`.
    const lib_tests = b.addTest(.{ .root_module = zeemo_mod });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_tests.step);

    // `zig build run-hello` for quick local smoke test.
    const run_hello = b.addRunArtifact(hello);
    if (b.args) |args| run_hello.addArgs(args);
    const run_hello_step = b.step("run-hello", "Run the hello-world example");
    run_hello_step.dependOn(&run_hello.step);
}
