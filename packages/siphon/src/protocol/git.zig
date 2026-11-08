//! The repositories on the machine as a client reads them, git asked: the repository a folder is in; the changes a
//! scope asks for — not yet committed, a branch's against its base, or one commit's — file by file; a file's patch
//! between the trees they were told between; its two versions there, which a view widens a patch's context with; and
//! the commits of a branch. Each is an act on the machine, as `on_machine` does one, the folder named whole.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Git = @import("../git.zig");
const Machine = @import("../machine.zig");
const on_machine = @import("on_machine.zig");

/// The repository a folder is in, none where it is in none.
pub const repository = on_machine.method(repositoryOf);
/// The changes `scope` asks for, of the repository a folder is in, and the two trees they are between.
pub const changes = on_machine.method(changesOf);
/// A file's patch between two trees the changes were told between, `context` lines about each change.
pub const patch = on_machine.method(patchOf);
/// A file's two versions in the two trees the changes were told between.
pub const versions = on_machine.method(versionsOf);
/// The commits of the branch of the repository a folder is in, since it parted from `base`.
pub const commits = on_machine.method(commitsOf);

/// Git, asked from the job `on` reaches the machine for, in memory of `arena`'s.
fn gitOf(arena: Allocator, on: on_machine.On) Git {
    return .{ .machine = on.machine, .io = on.io, .waits = on.waits, .arena = arena };
}

/// The folder a whole path names, as git is run in it.
fn folderOf(arena: Allocator, on: on_machine.On, path: []const u8) ![]const u8 {
    return Machine.paths.resolve(arena, on.machine.base, path);
}

fn repositoryOf(arena: Allocator, on: on_machine.On, given: struct { path: []const u8 }) !struct { repository: ?Git.Repository } {
    return .{ .repository = try gitOf(arena, on).repositoryOf(try folderOf(arena, on, given.path)) };
}

fn changesOf(arena: Allocator, on: on_machine.On, given: struct { path: []const u8, scope: Git.Scope }) !Git.Changes {
    return gitOf(arena, on).changesOf(try folderOf(arena, on, given.path), given.scope);
}

/// How many lines of context a patch holds about each change unless asked: as many as git writes.
const context_lines = 3;

fn patchOf(arena: Allocator, on: on_machine.On, given: struct { path: []const u8, comparison: Git.Comparison, file: Git.File, context: u32 = context_lines }) !struct { patch: []const u8 } {
    return .{ .patch = try gitOf(arena, on).patchOf(try folderOf(arena, on, given.path), given.comparison, given.file, given.context) };
}

fn versionsOf(arena: Allocator, on: on_machine.On, given: struct { path: []const u8, comparison: Git.Comparison, file: Git.File }) !Git.Versions {
    return gitOf(arena, on).versionsOf(try folderOf(arena, on, given.path), given.comparison, given.file);
}

fn commitsOf(arena: Allocator, on: on_machine.On, given: struct { path: []const u8, base: ?[]const u8 = null }) !@typeInfo(@typeInfo(@TypeOf(Git.commitsOf)).@"fn".return_type.?).error_union.payload {
    return gitOf(arena, on).commitsOf(try folderOf(arena, on, given.path), given.base);
}
