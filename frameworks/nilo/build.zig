//! nilo's entry in HttpArena, as one dependent would build it. `sql = true`
//! is what makes `nilo_sql` exist for a dependent at all (ADR 0075); a
//! program that never imported it would leave the option off and fetch no
//! driver.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `.tls = true` is what makes the TLS listener on 8081 exist at all: the
    // library behind it is fetched and linked only for a dependent that asks
    // (ADR 0288), and a build without it refuses `.tls` at `listen()` rather
    // than serving cleartext on a port the entry believed was encrypted.
    const nilo = b.dependency("nilo", .{ .target = target, .optimize = optimize, .sql = true, .tls = true });

    const exe = b.addExecutable(.{
        .name = "nilo-arena",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // A release build strips, the way nilo's own measured binaries
            // do: a panic still names the request (`nilo.panic`), and the
            // board never opens a debugger.
            .strip = optimize != .Debug,
            .imports = &.{
                .{ .name = "nilo_http", .module = nilo.module("nilo_http") },
                .{ .name = "nilo_sql", .module = nilo.module("nilo_sql") },
            },
        }),
    });
    b.installArtifact(exe);

    // `zig build test`: the handlers, as functions, with no server.
    const tests = b.addTest(.{ .root_module = exe.root_module });
    b.step("test", "Run the entry's own tests").dependOn(&b.addRunArtifact(tests).step);
}
