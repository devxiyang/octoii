//! The skills a thread's model is told of, found on the local machine in a test's folder: the person's own, then each
//! project folder's from its repository's root down to the workspace, the nearest of a name standing for the rest.
const std = @import("std");
const Siphon = @import("Siphon.zig");
const threads = @import("threads.zig");
const system = @import("agent.zig").system;
const testing = @import("testing.zig");
const beak = @import("beak.zig");
const h = beak.h;

/// A skill's file, saying its name and what it is for.
fn skillFile(name: []const u8, description: []const u8, arena: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(arena, "---\nname: {s}\ndescription: {s}\n---\n# {s}\n", .{ name, description, name });
}

test "the model is told of the skills it may use: its own and the project's, the nearest of a name for the rest" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const files = [_]struct { []const u8, []const u8, []const u8 }{
        // Above the repository, which begins where its `.git` is: no skill of the project's.
        .{ ".agents/skills/far/SKILL.md", "far", "Too far." },
        .{ "own/notes/SKILL.md", "notes", "Takes notes." },
        .{ "own/review/SKILL.md", "review", "Reviews, the person's way." },
        .{ "repo/.agents/skills/review/SKILL.md", "review", "Reviews, the project's way." },
        .{ "repo/work/.agents/skills/review/SKILL.md", "review", "Reviews closely." },
        .{ "repo/work/.agents/skills/deploy/SKILL.md", "deploy", "Deploys." },
    };
    for (files) |file| {
        try tmp.dir.createDirPath(io, std.fs.path.dirname(file[0]).?);
        try tmp.dir.writeFile(io, .{ .sub_path = file[0], .data = try skillFile(file[1], file[2], arena) });
    }
    try tmp.dir.createDirPath(io, "repo/.git");
    // A folder with no skill's file, and a file that says not what its skill is for, are no skills — the second told
    // of as a warning, expected here.
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    try tmp.dir.createDirPath(io, "repo/.agents/skills/empty");
    try tmp.dir.createDirPath(io, "repo/.agents/skills/vague");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.agents/skills/vague/SKILL.md", .data = "---\nname: vague\n---\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const machine = try testing.openLocalMachine();
    defer _ = h.beak_close(machine);
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try Siphon.open(std.testing.allocator, .{ .io = io, .clock = clock.clock(), .machine = machine, .skills = try std.fs.path.join(arena, &.{ root, "own" }) }, .{});
    defer siphon.close();
    const tid = try threads.create(siphon.runtime, arena, .{ .workspace = try std.fs.path.join(arena, &.{ root, "repo", "work" }) }, "create");

    // Told after the base and any instructions — the test's folder is in a repository of its own — and before the
    // environment, which varies the most.
    const told = try system.gathered(&siphon.sources, arena, tid);
    const at = for (told.sections, 0..) |section, index| {
        if (std.mem.eql(u8, section.name, "skills")) break index;
    } else return error.NoSkills;
    try std.testing.expectEqualStrings("environment", told.sections[at + 1].name);
    try std.testing.expectEqualStrings(try std.mem.replaceOwned(u8, arena,
        \\<skill name="deploy" path="ROOT/repo/work/.agents/skills/deploy/SKILL.md">
        \\Deploys.
        \\</skill>
        \\<skill name="notes" path="ROOT/own/notes/SKILL.md">
        \\Takes notes.
        \\</skill>
        \\<skill name="review" path="ROOT/repo/work/.agents/skills/review/SKILL.md">
        \\Reviews closely.
        \\</skill>
    , "ROOT", root), told.sections[at].text.?);
}
