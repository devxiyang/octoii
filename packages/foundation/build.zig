//! Builds foundation, what more than one of Octoii's packages needs: `zig build check` is its gate — its sources
//! formatted, its tests run — and `zig build test` runs the tests alone. It depends on Zig's standard library alone.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sanitize_thread = b.option(bool, "sanitize-thread", "Build the tests with ThreadSanitizer, which finds data races") orelse false;
    const foundation = b.addModule("foundation", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread });

    const tests = b.addTest(.{ .root_module = foundation });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run foundation's tests");
    test_step.dependOn(&run_tests.step);

    const format = b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("src") }, .check = true });
    const check_step = b.step("check", "Check foundation: its sources formatted and its tests passing");
    check_step.dependOn(&format.step);
    check_step.dependOn(&run_tests.step);
}
