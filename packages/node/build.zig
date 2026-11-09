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
    const imports = [_]std.Build.Module.Import{ .{ .name = "siphon", .module = siphon }, .{ .name = "tunnel", .module = tunnel } };
    const node = nodeModule(b, target, optimize, &imports);

    // The session a browser runs, from the tunnel the node itself is built on, for the web app to keep.
    const page_client = b.addInstallDirectory(.{ .source_dir = tunnel_package.namedLazyPath("page-client"), .install_dir = .prefix, .install_subdir = "page" });
    b.step("page-client", "Install the tunnel's page client into zig-out/page").dependOn(&page_client.step);

    const program = b.addExecutable(.{ .name = "octoii", .root_module = node });
    b.installArtifact(program);

    // Its tests, on a module of their own that also knows a played agent gateway, which they run on the machine as the
    // node runs the gateway.
    const played_gateway = b.addExecutable(.{ .name = "played-gateway", .root_module = b.createModule(.{ .root_source_file = b.path("src/testing/played_gateway.zig"), .target = target, .optimize = optimize }) });
    const test_options = b.addOptions();
    test_options.addOptionPath("played_gateway", played_gateway.getEmittedBin());
    const tested = nodeModule(b, target, optimize, &(imports ++ [_]std.Build.Module.Import{.{ .name = "test_options", .module = test_options.createModule() }}));
    const filters = b.option([]const []const u8, "test-filter", "Run only the tests whose names hold this") orelse &.{};
    const tests = b.addTest(.{ .root_module = tested, .filters = filters });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the node's tests");
    test_step.dependOn(&run_tests.step);

    const format = b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("src") }, .check = true });
    const lint = b.addRunArtifact(b.dependency("lint", .{}).artifact("lint"));
    lint.addDirectoryArg(b.path("src"));
    lint.has_side_effects = true;
    b.step("lint", "Check how the code holds memory and names its allocators").dependOn(&lint.step);
    const check_step = b.step("check", "Check the node: its sources formatted and linted, the program built and its tests passing");
    check_step.dependOn(&lint.step);
    check_step.dependOn(&format.step);
    check_step.dependOn(&program.step);
    check_step.dependOn(&run_tests.step);
}

/// The node's module, with `imports`: its sources, and the C that draws QR codes.
fn nodeModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, imports: []const std.Build.Module.Import) *std.Build.Module {
    const node = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = imports });
    node.addCSourceFile(.{ .file = b.dependency("qrcodegen", .{}).path("c/qrcodegen.c"), .flags = &.{"-std=c99"} });
    return node;
}
