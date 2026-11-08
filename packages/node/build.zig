//! Builds the node, Octoii's native host: the `octoii` program. `zig build check` is its gate — its sources formatted,
//! the program built, so every function it reaches is compiled, and its tests run — and `zig build` installs the
//! program. It reaches Siphon, and through it `ai` and Beak, and the tunnel its devices reach it through.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const siphon = b.dependency("siphon", .{ .target = target, .optimize = optimize }).module("siphon");
    const tunnel_package = b.dependency("tunnel", .{ .target = target, .optimize = optimize });
    const tunnel = tunnel_package.module("tunnel");
    const node = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{
        .{ .name = "siphon", .module = siphon },
        .{ .name = "tunnel", .module = tunnel },
    } });
    node.addCSourceFile(.{ .file = b.dependency("qrcodegen", .{}).path("c/qrcodegen.c"), .flags = &.{"-std=c99"} });

    // The session a browser runs, from the tunnel the node itself is built on, for the web app to keep.
    const page_client = b.addInstallDirectory(.{ .source_dir = tunnel_package.namedLazyPath("page-client"), .install_dir = .prefix, .install_subdir = "page" });
    b.step("page-client", "Install the tunnel's page client into zig-out/page").dependOn(&page_client.step);

    const program = b.addExecutable(.{ .name = "octoii", .root_module = node });
    b.installArtifact(program);

    const tests = b.addTest(.{ .root_module = node });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the node's tests");
    test_step.dependOn(&run_tests.step);

    const format = b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("src") }, .check = true });
    const check_step = b.step("check", "Check the node: its sources formatted, the program built and its tests passing");
    check_step.dependOn(&format.step);
    check_step.dependOn(&program.step);
    check_step.dependOn(&run_tests.step);
}
