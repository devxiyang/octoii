//! Builds ai, Octoii's access to models: `vocabulary`, the model protocol, a module of its own that a reader of a
//! conversation imports alone, and `ai`, the rest. `zig build check` is its gate — its sources formatted, its tests run — and `zig build test` runs
//! the tests alone. It depends on foundation alone.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sanitize_thread = b.option(bool, "sanitize-thread", "Build the tests with ThreadSanitizer, which finds data races") orelse false;
    const foundation = b.dependency("foundation", .{ .target = target, .optimize = optimize, .@"sanitize-thread" = sanitize_thread }).module("foundation");
    const vocabulary = b.addModule("vocabulary", .{
        .root_source_file = b.path("src/vocabulary/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .imports = &.{.{ .name = "foundation", .module = foundation }},
    });
    const ai = b.addModule("ai", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .imports = &.{
            .{ .name = "foundation", .module = foundation },
            .{ .name = "vocabulary", .module = vocabulary },
        },
    });

    const test_step = b.step("test", "Run ai's tests");
    for ([_]*std.Build.Module{ vocabulary, ai }) |module| {
        const tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    const format = b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("src") }, .check = true });
    const lint = b.addRunArtifact(b.dependency("lint", .{}).artifact("lint"));
    lint.addDirectoryArg(b.path("src"));
    lint.has_side_effects = true;
    b.step("lint", "Check how the code holds memory and names its allocators").dependOn(&lint.step);
    const check_step = b.step("check", "Check ai: its sources formatted and linted and its tests passing");
    check_step.dependOn(&lint.step);
    check_step.dependOn(&format.step);
    check_step.dependOn(test_step);
}
