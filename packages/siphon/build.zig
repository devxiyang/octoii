//! Builds Siphon: `zig build check` is its gate — its sources formatted, its tests run — and `zig build test` runs the
//! tests alone, linked with Beak's static library, which `scripts/beak.sh` brings into `vendor/beak/<arch>-<os>/`
//! beside its header. Siphon builds and checks on its own, apart from the workspace's TypeScript.
const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const beak = beakOf(b, target);
    const sanitize_thread = b.option(bool, "sanitize-thread", "Build the tests with ThreadSanitizer, which finds data races") orelse false;
    const foundation = b.dependency("foundation", .{ .target = target, .optimize = optimize, .@"sanitize-thread" = sanitize_thread }).module("foundation");
    const ai_package = b.dependency("ai", .{ .target = target, .optimize = optimize, .@"sanitize-thread" = sanitize_thread });
    const vocabulary = ai_package.module("vocabulary");
    const ai = ai_package.module("ai");
    const typebox = b.dependency("typebox", .{ .target = target, .optimize = optimize }).module("typebox");
    const mcp_package = b.dependency("mcp", .{ .target = target, .optimize = optimize, .@"sanitize-thread" = sanitize_thread });
    const imports = [_]std.Build.Module.Import{
        .{ .name = "foundation", .module = foundation },
        .{ .name = "vocabulary", .module = vocabulary },
        .{ .name = "ai", .module = ai },
        .{ .name = "typebox", .module = typebox },
        .{ .name = "mcp", .module = mcp_package.module("mcp") },
    };

    // The script engine's QuickJS: quickts, compiled once for both of Siphon's modules.
    const quickts = b.dependency("quickts", .{});
    const engine = quicktsLibrary(b, quickts, target);
    // The images' C: Wuffs and stb beneath `src/image/codec.c`, compiled once for both modules.
    const codecs = imageLibrary(b, target);
    // The shell's grammar: tree-sitter and its Bash grammar, compiled once for both modules.
    const grammar = shellLibrary(b, target);

    // Siphon, for its host to import: Beak linked into it, and `ai`, `vocabulary` and `foundation` given through it, so
    // a host and Siphon share their types.
    const siphon = b.addModule("siphon", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = true, .sanitize_thread = sanitize_thread, .imports = &imports });
    withBeak(b, siphon, target, optimize, beak);
    withScriptEngine(b, siphon, quickts, engine);
    siphon.linkLibrary(codecs);
    siphon.linkLibrary(grammar);

    // Its tests, on a module of their own that also knows mcp's example server, which they run on the machine.
    const test_options = b.addOptions();
    test_options.addOptionPath("example_stdio_server", mcp_package.artifact("example-stdio-server").getEmittedBin());
    const tested = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = true, .sanitize_thread = sanitize_thread, .imports = &(imports ++ [_]std.Build.Module.Import{.{ .name = "test_options", .module = test_options.createModule() }}) });
    withBeak(b, tested, target, optimize, beak);
    withScriptEngine(b, tested, quickts, engine);
    tested.linkLibrary(codecs);
    tested.linkLibrary(grammar);
    const filters = b.option([]const []const u8, "test-filter", "Run only the tests whose names hold this") orelse &.{};
    const tests = b.addTest(.{ .root_module = tested, .filters = filters });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run Siphon's tests");
    test_step.dependOn(&run_tests.step);

    const format = b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("src") }, .check = true });
    const check_step = b.step("check", "Check Siphon: its sources formatted and its tests passing");
    check_step.dependOn(&format.step);
    check_step.dependOn(&run_tests.step);
}

/// Where Beak's build for `target` is: its static library and its header.
fn beakOf(b: *std.Build, target: std.Build.ResolvedTarget) std.Build.LazyPath {
    const triple = b.fmt("{s}-{s}", .{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag) });
    return b.path(b.fmt("vendor/beak/{s}", .{triple}));
}

/// Links Beak into `module`: its library whole, `beak.h` translated as the module `beak_h`, and what Beak needs of the
/// system.
fn withBeak(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, beak: std.Build.LazyPath) void {
    module.addObjectFile(beak.path(b, "libbeak.a"));
    const header: Translator = .init(b.dependency("translate_c", .{}), .{ .name = "beak_h", .c_source_file = beak.path(b, "beak.h"), .target = target, .optimize = optimize });
    module.addImport("beak_h", header.mod);
    if (target.result.os.tag == .macos) module.linkFramework("CoreServices", .{});
}

/// quickts's sources — QuickJS whose parser reads TypeScript — Temporal and Intl with them, as its build compiles them.
const quickts_sources = [_][]const u8{
    "quickjs.c",                "libregexp.c",              "libunicode.c",         "cutils.c",                  "dtoa.c",
    "intl/intl.c",              "intl/locale.c",            "intl/locale-data.c",   "intl/numberformat.c",       "intl/collator.c",
    "intl/datetimeformat.c",    "intl/pluralrules.c",       "intl/listformat.c",    "intl/relativetimeformat.c", "intl/displaynames.c",
    "intl/segmenter.c",         "intl/durationformat.c",    "temporal/temporal.c",  "temporal/instant.c",        "temporal/duration.c",
    "temporal/plaintime.c",     "temporal/now.c",           "temporal/plaindate.c", "temporal/plaindatetime.c",  "temporal/plainyearmonth.c",
    "temporal/plainmonthday.c", "temporal/zoneddatetime.c", "temporal/calendar.c",  "temporal/timezone.c",       "temporal/tzdata_generated.c",
};

/// What the script engine's C compiles with, its glue and quickts alike.
const script_flags: []const []const u8 = &.{ "-std=gnu11", "-fno-sanitize=undefined", "-fwrapv", "-D_GNU_SOURCE", "-DCONFIG_VERSION=\"2026-06-04\"", "-DCONFIG_TEMPORAL_INTL" };

/// quickts as a library, compiled optimized whatever Siphon's own mode, so a Debug build runs no unoptimized engine.
fn quicktsLibrary(b: *std.Build, quickts: *std.Build.Dependency, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    const module = b.createModule(.{ .target = target, .optimize = .fast, .link_libc = true });
    module.addIncludePath(quickts.path(""));
    module.addCSourceFiles(.{ .root = quickts.path(""), .files = &quickts_sources, .flags = script_flags });
    return b.addLibrary(.{ .name = "quickts", .linkage = .static, .root_module = module });
}

/// Gives `module` the script engine: its glue to QuickJS, `src/script/engine.c`, and quickts, `engine`, linked.
fn withScriptEngine(b: *std.Build, module: *std.Build.Module, quickts: *std.Build.Dependency, engine: *std.Build.Step.Compile) void {
    module.addIncludePath(quickts.path(""));
    module.addCSourceFile(.{ .file = b.path("src/script/engine.c"), .flags = script_flags });
    module.linkLibrary(engine);
}

/// The images' C as a library: `src/image/codec.c` on Wuffs, stb_image_write and stb_image_resize2, compiled optimized
/// whatever Siphon's own mode, as decoding and resizing are the work of every image.
fn imageLibrary(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    const module = b.createModule(.{ .target = target, .optimize = .fast, .link_libc = true });
    module.addIncludePath(b.dependency("wuffs", .{}).path("release/c"));
    module.addIncludePath(b.dependency("stb", .{}).path(""));
    module.addIncludePath(b.dependency("stb_image_resize", .{}).path(""));
    module.addCSourceFile(.{ .file = b.path("src/image/codec.c"), .flags = &.{ "-std=c11", "-fno-sanitize=undefined" } });
    return b.addLibrary(.{ .name = "image", .linkage = .static, .root_module = module });
}

/// tree-sitter and its Bash grammar as a library, compiled optimized whatever Siphon's own mode, as every command line a
/// call runs is read by them.
fn shellLibrary(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    const tree_sitter = b.dependency("tree_sitter", .{});
    const bash = b.dependency("tree_sitter_bash", .{});
    const module = b.createModule(.{ .target = target, .optimize = .fast, .link_libc = true });
    module.addIncludePath(tree_sitter.path("lib/include"));
    module.addIncludePath(tree_sitter.path("lib/src"));
    module.addIncludePath(bash.path("src"));
    const flags: []const []const u8 = &.{ "-std=c11", "-fno-sanitize=undefined", "-fvisibility=hidden", "-D_POSIX_C_SOURCE=200112L", "-D_DEFAULT_SOURCE", "-D_DARWIN_C_SOURCE" };
    module.addCSourceFile(.{ .file = tree_sitter.path("lib/src/lib.c"), .flags = flags });
    module.addCSourceFiles(.{ .root = bash.path("src"), .files = &.{ "parser.c", "scanner.c" }, .flags = flags });
    return b.addLibrary(.{ .name = "shell", .linkage = .static, .root_module = module });
}
