//! Permissions: whether a call goes ahead, and where its commands may write — as its thread's mode, what the person
//! granted its project and, in auto, a second model's judgment say — weighed by what its tool says it does, and to
//! what: the files it edits, the simple commands it runs, or a tool that may act on anything, by its name.
//!
//! In `default`, an edit within the workspace and a command within the system's sandbox — writing the workspace and the
//! temporary folders alone — go ahead; a command that asks to write beyond the sandbox, every command where the machine
//! sandboxes none, an edit beyond the workspace and a tool of a server ask the person. In `auto`, nothing is sandboxed:
//! an edit within the workspace and a command line that reads alone go ahead, and everything else a second model
//! judges. In `full-access`, everything goes ahead. In every mode, what the person granted the project goes ahead,
//! writing anywhere; and nothing reaches what the host keeps for itself, as the machine keeps it.
//!
//! A call that asks makes a durable `permission` request, which the person answers once; always — the call's patterns
//! granted its thread's project, kept under `siphon.grants` by the digest of the project's folder; or not, with words
//! the model reads.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const typebox = @import("typebox");
const beak = @import("../beak.zig");
const threads = @import("../threads.zig");
const Runtime = @import("../runtime.zig").Runtime;
const Changes = @import("../runtime.zig").Changes;
const Tool = @import("Tool.zig");

/// The name of the request a call that asks makes.
pub const request_name = "permission";

/// What the person is asked: the call, as the model made it, what it does to the machine, and why a second model
/// would not let it go ahead, where one judged it.
pub const Asked = struct { tool: []const u8, arguments: foundation.json.Raw, access: Tool.Access, doubt: ?[]const u8 = null };

/// The person's answer: once; always, the call's patterns granted its thread's project; or reject, with words the
/// model reads.
pub const Answer = struct { reply: Reply, message: ?[]const u8 = null };
pub const Reply = enum { once, always, reject };

/// What the person granted a project, as its file under `siphon.grants` keeps it: its folder, and the patterns of each
/// action its threads' later calls go ahead by.
pub const Grants = struct { folder: []const u8 = "", allow: []const Grant = &.{} };
pub const Grant = struct { action: Tool.Action, pattern: []const u8 };

/// The folder the projects' grants are kept in, a file for each project.
pub const grants_folder = "siphon.grants";

/// How a call is weighed: it goes ahead, its commands writing where `go` says; it asks the person first; or a second
/// model judges it. What the person or the model lets go ahead writes anywhere.
pub const Weighed = union(enum) { go: Tool.Writes, ask, review };

/// Has the person answer every permission request.
pub fn register(runtime: *Runtime) !void {
    try runtime.askPerson(request_name, .{ .fixed = typebox.of(Answer) });
}

/// A call as it is weighed: what it does to the machine, none for a tool that acts on nothing; its thread's mode, its
/// workspace — none where it has none — and what the person granted its project; and whether the machine sandboxes
/// commands.
pub const Call = struct {
    access: ?Tool.Access,
    mode: threads.Mode,
    workspace: ?[]const u8,
    grants: Grants,
    sandboxes: bool = true,
};

/// How `call` is weighed, as its thread's mode and its project's grants say: what goes ahead with no one judging it
/// goes ahead, in `default` kept within the sandbox; what must be judged goes ahead where the person granted it the
/// project, else is judged — by the person, or in auto by a second model.
pub fn weigh(call: Call) Weighed {
    const access = call.access orelse return .{ .go = unjudged(call.mode) };
    switch (call.mode) {
        .default => switch (access.action) {
            .edit => if (allWithin(access.resources, call.workspace)) return .{ .go = .workspace },
            .command => if (!access.escalate and call.sandboxes) return .{ .go = .workspace },
            .tool => {},
        },
        .auto => switch (access.action) {
            .edit => if (allWithin(access.resources, call.workspace)) return .{ .go = .anywhere },
            .command => if (access.reads_alone) return .{ .go = .anywhere },
            .tool => {},
        },
        .@"full-access" => return .{ .go = .anywhere },
    }
    if (granted(call.grants, access)) return .{ .go = .anywhere };
    return if (call.mode == .auto) .review else .ask;
}

/// Where what goes ahead with no one judging it writes, in a thread of `mode`: in `default` within the sandbox alone.
fn unjudged(mode: threads.Mode) Tool.Writes {
    return if (mode == .default) .workspace else .anywhere;
}

/// Whether every one of `places` is within `folder`; none is not, nor is anything within no folder.
fn allWithin(places: []const []const u8, folder: ?[]const u8) bool {
    const base = folder orelse return false;
    for (places) |place| if (!within(place, base)) return false;
    return places.len > 0;
}

/// Whether `place` is `folder` or beneath it.
fn within(place: []const u8, folder: []const u8) bool {
    if (!std.mem.startsWith(u8, place, folder)) return false;
    return place.len == folder.len or std.fs.path.isSep(place[folder.len]) or (folder.len > 0 and std.fs.path.isSep(folder[folder.len - 1]));
}

/// Whether the grants let `access` go ahead: each of what it acts on matched by a pattern of its action's — never where
/// nothing it acts on could be read.
fn granted(grants: Grants, access: Tool.Access) bool {
    for (access.resources) |resource| {
        const matched = for (grants.allow) |each| {
            if (each.action == access.action and matches(each.pattern, resource)) break true;
        } else false;
        if (!matched) return false;
    }
    return access.resources.len > 0;
}

/// Whether `text` matches `pattern`, whose `*` stands for any run of characters, none too; a pattern ending in ` *`
/// matches the text before it alone too, as `ls *` matches `ls`.
pub fn matches(pattern: []const u8, text: []const u8) bool {
    if (std.mem.endsWith(u8, pattern, " *") and std.mem.eql(u8, pattern[0 .. pattern.len - 2], text)) return true;
    return globbed(pattern, text);
}

fn globbed(pattern: []const u8, text: []const u8) bool {
    const star = std.mem.indexOfScalar(u8, pattern, '*') orelse return std.mem.eql(u8, pattern, text);
    if (!std.mem.startsWith(u8, text, pattern[0..star])) return false;
    const rest = pattern[star + 1 ..];
    var from = star;
    while (from <= text.len) : (from += 1) if (globbed(rest, text[from..])) return true;
    return false;
}

/// The file the grants of the project at `folder` are kept in: named by its folder's digest.
fn grantsPath(arena: Allocator, folder: []const u8) ![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(folder, &digest, .{});
    return std.fmt.allocPrint(arena, "{s}/{s}.json", .{ grants_folder, &std.fmt.bytesToHex(digest, .lower) });
}

/// What the person granted the project at `folder`: none where they granted it nothing, or where there is no project.
pub fn grantsOf(runtime: *const Runtime, arena: Allocator, folder: ?[]const u8) !Grants {
    const project = folder orelse return .{};
    const text = runtime.volume.readAll(&arena, try grantsPath(arena, project)) catch |err| switch (err) {
        error.NotFound => return .{ .folder = project },
        else => return err,
    };
    return foundation.json.decode(Grants, arena, text);
}

/// Grants the project `grants` are of the patterns `save` of `action`, with `changes`, besides what it was granted.
pub fn grant(changes: *Changes, arena: Allocator, grants: Grants, action: Tool.Action, save: []const []const u8) !void {
    if (grants.folder.len == 0) return error.NoProject;
    var allow: std.ArrayList(Grant) = .empty;
    try allow.appendSlice(arena, grants.allow);
    for (save) |pattern| {
        const known = for (grants.allow) |each| {
            if (each.action == action and std.mem.eql(u8, each.pattern, pattern)) break true;
        } else false;
        if (!known) try allow.append(arena, .{ .action = action, .pattern = pattern });
    }
    try changes.mkdir(grants_folder);
    try changes.write(try grantsPath(arena, grants.folder), try foundation.json.encode(arena, Grants{ .folder = grants.folder, .allow = allow.items }));
}

/// Takes back from the project at `folder` the grant of `pattern` to `action`, with `changes`: its file gone with the
/// last of them; nothing where it was not granted.
pub fn revoke(changes: *Changes, runtime: *const Runtime, arena: Allocator, folder: []const u8, action: Tool.Action, pattern: []const u8) !void {
    const grants = try grantsOf(runtime, arena, folder);
    var allow: std.ArrayList(Grant) = .empty;
    for (grants.allow) |each| if (each.action != action or !std.mem.eql(u8, each.pattern, pattern)) try allow.append(arena, each);
    if (allow.items.len == grants.allow.len) return;
    const path = try grantsPath(arena, folder);
    if (allow.items.len == 0) return changes.delete(path);
    try changes.write(path, try foundation.json.encode(arena, Grants{ .folder = folder, .allow = allow.items }));
}

/// What the person granted every project, a project a list of grants, in the order of their files.
pub fn every(runtime: *const Runtime, arena: Allocator) ![]const Grants {
    var found: std.ArrayList(Grants) = .empty;
    const entries = runtime.volume.list(&arena, grants_folder, "") catch |err| switch (err) {
        error.NotFound => return found.items,
        else => return err,
    };
    for (entries) |entry| {
        const text = try runtime.volume.readAll(&arena, try beak.join(arena, grants_folder, beak.slice(entry.name)));
        try found.append(arena, try foundation.json.decode(Grants, arena, text));
    }
    return found.items;
}

/// A call weighed in a thread of `mode` working in `/work/app`, its project granted `grants`.
fn callOf(mode: threads.Mode, access: ?Tool.Access, grants: Grants) Call {
    return .{ .access = access, .mode = mode, .workspace = "/work/app", .grants = grants };
}

test "an edit within the workspace goes ahead; one beyond it asks in default, is judged in auto and goes ahead in full access" {
    const inside: Tool.Access = .{ .action = .edit, .resources = &.{"/work/app/src/a.zig"}, .save = &.{"*"} };
    const outside: Tool.Access = .{ .action = .edit, .resources = &.{"/work/other/b.zig"}, .save = &.{"*"} };
    try std.testing.expectEqual(Weighed{ .go = .workspace }, weigh(callOf(.default, inside, .{})));
    try std.testing.expectEqual(Weighed.ask, weigh(callOf(.default, outside, .{})));
    try std.testing.expectEqual(Weighed.review, weigh(callOf(.auto, outside, .{})));
    try std.testing.expectEqual(Weighed{ .go = .anywhere }, weigh(callOf(.@"full-access", outside, .{})));
    // Granted every edit, none asks.
    const every_edit: Grants = .{ .folder = "/work/app", .allow = &.{.{ .action = .edit, .pattern = "*" }} };
    try std.testing.expectEqual(Weighed{ .go = .anywhere }, weigh(callOf(.default, outside, every_edit)));
    // The workspace is matched by its path's parts, not its letters; a thread of no workspace has nothing within it.
    const beside: Tool.Access = .{ .action = .edit, .resources = &.{"/work/application/c.zig"}, .save = &.{"*"} };
    try std.testing.expectEqual(Weighed.ask, weigh(callOf(.default, beside, .{})));
    var nowhere = callOf(.default, inside, .{});
    nowhere.workspace = null;
    try std.testing.expectEqual(Weighed.ask, weigh(nowhere));
}

test "in default a command runs in the system's sandbox, asks beyond it or where the machine sandboxes none, and goes ahead where each of it is granted" {
    const install: Tool.Access = .{ .action = .command, .resources = &.{ "npm install lodash", "git push" }, .save = &.{ "npm install *", "git push *" } };
    try std.testing.expectEqual(Weighed{ .go = .workspace }, weigh(callOf(.default, install, .{})));
    var beyond = install;
    beyond.escalate = true;
    try std.testing.expectEqual(Weighed.ask, weigh(callOf(.default, beyond, .{})));
    var unconfined = callOf(.default, install, .{});
    unconfined.sandboxes = false;
    try std.testing.expectEqual(Weighed.ask, weigh(unconfined));
    const both: Grants = .{ .folder = "/work/app", .allow = &.{ .{ .action = .command, .pattern = "npm install *" }, .{ .action = .command, .pattern = "git push *" } } };
    try std.testing.expectEqual(Weighed{ .go = .anywhere }, weigh(callOf(.default, beyond, both)));
    // One of it not granted, or a line nothing of which could be read, asks.
    const removing: Tool.Access = .{ .action = .command, .resources = &.{ "npm install lodash", "rm -rf build" }, .save = &.{ "npm install *", "rm *" }, .escalate = true };
    try std.testing.expectEqual(Weighed.ask, weigh(callOf(.default, removing, both)));
    const unread: Tool.Access = .{ .action = .command, .resources = &.{}, .save = &.{}, .escalate = true };
    try std.testing.expectEqual(Weighed.ask, weigh(callOf(.default, unread, .{ .folder = "/work/app", .allow = &.{.{ .action = .command, .pattern = "git *" }} })));
}

test "in auto, a line that reads alone goes ahead and the rest is judged, but what the project was granted" {
    const listing: Tool.Access = .{ .action = .command, .resources = &.{"ls -la"}, .save = &.{"ls *"}, .reads_alone = true };
    try std.testing.expectEqual(Weighed{ .go = .anywhere }, weigh(callOf(.auto, listing, .{})));
    const testing_: Tool.Access = .{ .action = .command, .resources = &.{"npm test"}, .save = &.{"npm test *"} };
    try std.testing.expectEqual(Weighed.review, weigh(callOf(.auto, testing_, .{})));
    const tests_granted: Grants = .{ .folder = "/work/app", .allow = &.{.{ .action = .command, .pattern = "npm test *" }} };
    try std.testing.expectEqual(Weighed{ .go = .anywhere }, weigh(callOf(.auto, testing_, tests_granted)));
}

test "a tool that may act on anything asks in default, is judged in auto, goes ahead in full access, and once granted by its name" {
    const create: Tool.Access = .{ .action = .tool, .resources = &.{"github.create_issue"}, .save = &.{"github.create_issue"} };
    try std.testing.expectEqual(Weighed.ask, weigh(callOf(.default, create, .{})));
    try std.testing.expectEqual(Weighed.review, weigh(callOf(.auto, create, .{})));
    try std.testing.expectEqual(Weighed{ .go = .anywhere }, weigh(callOf(.@"full-access", create, .{})));
    const by_name: Grants = .{ .folder = "/work/app", .allow = &.{.{ .action = .tool, .pattern = "github.create_issue" }} };
    try std.testing.expectEqual(Weighed{ .go = .anywhere }, weigh(callOf(.default, create, by_name)));
    // A grant of one action lets no other go ahead.
    const edits: Grants = .{ .folder = "/work/app", .allow = &.{.{ .action = .edit, .pattern = "*" }} };
    try std.testing.expectEqual(Weighed.ask, weigh(callOf(.default, create, edits)));
    // A tool that acts on nothing goes ahead in every mode.
    try std.testing.expectEqual(Weighed{ .go = .workspace }, weigh(callOf(.default, null, .{})));
    try std.testing.expectEqual(Weighed{ .go = .anywhere }, weigh(callOf(.auto, null, .{})));
}

test "a pattern's star stands for any run of characters, and a trailing one for none" {
    try std.testing.expect(matches("npm install *", "npm install lodash"));
    try std.testing.expect(matches("ls *", "ls"));
    try std.testing.expect(matches("*", "/anything/at/all"));
    try std.testing.expect(!matches("npm install *", "npm installer"));
    try std.testing.expect(matches("git *", "git push origin main"));
    try std.testing.expect(!matches("git push *", "git pull"));
}
