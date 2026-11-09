//! Builds mcp, Octoii's client and server of the Model Context Protocol. `zig build check` is its gate — its sources
//! formatted, its tests run — and `zig build test` runs the tests alone. It depends on foundation and typebox alone. The
//! tests run an example server over stdio, a program built beside them.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sanitize_thread = b.option(bool, "sanitize-thread", "Build the tests with ThreadSanitizer, which finds data races") orelse false;
    const foundation = b.dependency("foundation", .{ .target = target, .optimize = optimize, .@"sanitize-thread" = sanitize_thread }).module("foundation");
    const typebox = b.dependency("typebox", .{ .target = target, .optimize = optimize }).module("typebox");
    _ = b.addModule("mcp", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "foundation", .module = foundation }, .{ .name = "typebox", .module = typebox } },
    });

    const example_stdio_server = b.addExecutable(.{ .name = "example-stdio-server", .root_module = b.createModule(.{
        .root_source_file = b.path("src/example_stdio_server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "foundation", .module = foundation }, .{ .name = "typebox", .module = typebox } },
    }) });
    // Installed, so a package that depends on mcp tests against it too.
    b.installArtifact(example_stdio_server);
    const test_options = b.addOptions();
    test_options.addOptionPath("example_stdio_server", example_stdio_server.getEmittedBin());

    const test_step = b.step("test", "Run mcp's tests");
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "foundation", .module = foundation },
            .{ .name = "typebox", .module = typebox },
            .{ .name = "test_options", .module = test_options.createModule() },
        },
    }) });
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const format = b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("src") }, .check = true });
    const lint = b.addRunArtifact(b.dependency("lint", .{}).artifact("lint"));
    lint.addDirectoryArg(b.path("src"));
    lint.has_side_effects = true;
    b.step("lint", "Check how the code holds memory and names its allocators").dependOn(&lint.step);
    const check_step = b.step("check", "Check mcp: its sources formatted and linted and its tests passing");
    check_step.dependOn(&lint.step);
    check_step.dependOn(&format.step);
    check_step.dependOn(test_step);
}
