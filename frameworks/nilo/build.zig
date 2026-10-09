//! nilo's entry in HttpArena, as one dependent would build it. `sql = true`
//! is what makes `nilo_sql` exist for a dependent at all (ADR 0075); a
//! program that never imported it would leave the option off and fetch no
//! driver.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Four flags, each of which keeps its dependency out of a build that does
    // not ask:
    //
    // `.tls = true` makes the TLS listeners on 8081 and 8443 exist at all: the
    // library behind it is fetched and linked only for a dependent that asks
    // (ADR 212), and a build without it refuses `.tls` at `listen()` rather
    // than serving cleartext on a port the entry believed was encrypted.
    //
    // `.http2 = true` builds HTTP/2 and gRPC into the one server (ADR 259,
    // ADR 220): a plain listener tells h2c from HTTP/1.1 by the first bytes,
    // and a TLS one offers `h2` and `http/1.1` by ALPN. It brings no
    // dependency, only code.
    //
    // `.libdeflate = true` makes `app.compress` gzip with libdeflate instead of
    // `std.flate` (ADR 248), which is what `json-comp` spends its time on.
    const nilo = b.dependency("nilo", .{
        .target = target,
        .optimize = optimize,
        .sql = true,
        .tls = true,
        .http2 = true,
        .libdeflate = true,
    });

    // zio itself, at the commit nilo pins, because `zio_options` is typed
    // `zio.Options` and nilo does not re-export zio. The arguments are the
    // ones nilo's own build passes, so this is the same zio nilo links and not
    // a second copy; the scheduling the program runs is the root file's
    // `zio_options`, which overrides this build option.
    const zio = b.dependency("zio", .{ .target = target, .optimize = optimize, .scheduling = .pinned });

    const exe = b.addExecutable(.{
        .name = "nilo-arena",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // A release build strips, the way nilo's own measured binaries
            // do: a panic still names the request (`nilo.panic`), and the
            // board never opens a debugger.
            .strip = optimize != .debug,
            .imports = &.{
                .{ .name = "nilo_http", .module = nilo.module("nilo_http") },
                .{ .name = "nilo_sql", .module = nilo.module("nilo_sql") },
                .{ .name = "zio", .module = zio.module("zio") },
            },
        }),
    });
    b.installArtifact(exe);

    // `zig build test`: the handlers, as functions, with no server.
    const tests = b.addTest(.{ .root_module = exe.root_module });
    b.step("test", "Run the entry's own tests").dependOn(&b.addRunArtifact(tests).step);
}
