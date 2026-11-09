//! Builds the lint of Octoii's Zig, which reads how the code holds memory and names its allocators from each file's
//! syntax tree: `zig build check` is its gate — its sources formatted, its tests run and itself linted — and every
//! package's own check runs its `lint` artifact over the package's sources.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const lint_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = b.graph.host, .optimize = .debug });
    const lint = b.addExecutable(.{ .name = "lint", .root_module = lint_module });
    b.installArtifact(lint);

    const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = lint_module }));
    const test_step = b.step("test", "Run the lint's tests");
    test_step.dependOn(&run_tests.step);

    const linted = b.addRunArtifact(lint);
    linted.addDirectoryArg(b.path("src"));
    linted.has_side_effects = true;
    const format = b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("src") }, .check = true });
    const check_step = b.step("check", "Check the lint: its sources formatted, its tests passing and itself linted");
    check_step.dependOn(&format.step);
    check_step.dependOn(&run_tests.step);
    check_step.dependOn(&linted.step);
}
