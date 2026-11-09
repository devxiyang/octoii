//! Paths on the machine a thread works on, as its model writes them and reads them back. A path is taken, whatever its
//! spelling, as the place it names: relative to the thread's workspace, as a shell takes one against its working
//! folder; `~` the home folder; `.`, `..` and repeated separators resolved by their names alone, as a Plan 9 namespace
//! resolves them. A place is shown as the model would write it again: relative inside the workspace, absolute outside.
//! Nothing is guessed, and no place is out of bounds: what a thread may reach is where it runs.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Where a thread's paths start: its workspace, by its absolute path, and the home folder `~` names, where the host
/// knows one.
pub const Base = struct { workspace: []const u8, home: ?[]const u8 = null };

/// The absolute path, clean, that `given` names.
pub fn resolve(arena: Allocator, base: Base, given: []const u8) ![]const u8 {
    return std.fs.path.resolve(arena, &.{ base.workspace, try expandHome(arena, base.home, given) });
}

/// `given` with a leading `~` as the home folder, where there is one.
fn expandHome(arena: Allocator, home: ?[]const u8, given: []const u8) ![]const u8 {
    const folder = home orelse return given;
    if (std.mem.eql(u8, given, "~")) return folder;
    if (given.len > 1 and given[0] == '~' and std.fs.path.isSep(given[1])) return std.fs.path.join(arena, &.{ folder, given[2..] });
    return given;
}

/// The absolute, clean path `place` as the model reads it: relative to the workspace inside it, `.` for the workspace
/// itself, else as it is.
pub fn shown(arena: Allocator, base: Base, place: []const u8) ![]const u8 {
    const workspace = try std.fs.path.resolve(arena, &.{base.workspace});
    if (std.mem.eql(u8, place, workspace)) return ".";
    if (std.mem.startsWith(u8, place, workspace) and place.len > workspace.len and std.fs.path.isSep(place[workspace.len])) {
        return place[workspace.len + 1 ..];
    }
    return place;
}

test "a path names one place whatever its spelling, and is shown back as the model would write it" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const base: Base = .{ .workspace = "/work/app", .home = "/home/me" };
    const Case = struct { given: []const u8, place: []const u8, shown: []const u8 };
    const cases = [_]Case{
        .{ .given = "src/main.zig", .place = "/work/app/src/main.zig", .shown = "src/main.zig" },
        .{ .given = "./src//main.zig", .place = "/work/app/src/main.zig", .shown = "src/main.zig" },
        .{ .given = "src/../build.zig", .place = "/work/app/build.zig", .shown = "build.zig" },
        .{ .given = "src/", .place = "/work/app/src", .shown = "src" },
        .{ .given = "", .place = "/work/app", .shown = "." },
        .{ .given = ".", .place = "/work/app", .shown = "." },
        .{ .given = "/work/app/src", .place = "/work/app/src", .shown = "src" },
        .{ .given = "../lib/x.zig", .place = "/work/lib/x.zig", .shown = "/work/lib/x.zig" },
        .{ .given = "/etc/hosts", .place = "/etc/hosts", .shown = "/etc/hosts" },
        .{ .given = "~/.config/app.toml", .place = "/home/me/.config/app.toml", .shown = "/home/me/.config/app.toml" },
        .{ .given = "~", .place = "/home/me", .shown = "/home/me" },
        .{ .given = "~me/x", .place = "/work/app/~me/x", .shown = "~me/x" },
        .{ .given = "/work/application", .place = "/work/application", .shown = "/work/application" },
    };
    for (cases) |case| {
        const place = try resolve(arena, base, case.given);
        try std.testing.expectEqualStrings(case.place, place);
        try std.testing.expectEqualStrings(case.shown, try shown(arena, base, place));
    }
    // With no home folder known, `~` is a name like any other, as a shell without one leaves it.
    try std.testing.expectEqualStrings("/work/app/~/x", try resolve(arena, .{ .workspace = "/work/app" }, "~/x"));
}
