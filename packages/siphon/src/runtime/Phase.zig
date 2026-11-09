//! A phase of a fiber, as its program runs it: what Beak gave this run — its process, its input, the checkpoint it runs
//! from — and what the phase gives back, the changes of one commit and how it ends, committed together. A phase reads
//! what is committed, decides once, and commits once; to go on from what it committed, it ends `next`.
//!
//! What a phase writes into a fiber's process — an input, a request's payload, a checkpoint, a result — is JSON, every
//! one, encoded here alone from the value it is given: a `Raw` its text as it is, JSON already; null nothing; `kept` the
//! checkpoint the phase ran from. A failure's reason alone is text, as a process's error is.
const Phase = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const beak = @import("../beak.zig");
const h = beak.h;
const Runtime = @import("Runtime.zig");
const Request = @import("Request.zig");
const Changes = @import("Changes.zig");

/// Lives until what the phase gives back is committed.
arena: Allocator,
runtime: *Runtime,
/// The process the phase runs for, by its path, in the arena.
path: []const u8,
/// The process's input and the checkpoint the phase runs from, read in place: good for the phase's call alone, so what
/// the phase gives back of them is copied.
input: []const u8,
checkpoint: []const u8,
/// Whether this is the process's stop handler, run once it was asked to stop: its ending is the process's.
stop_handler: bool,
/// The time of the dispatch that runs the phase.
time: i64,
changes: Changes,
ending: h.beak_ending = endingOf(h.BEAK_ENDING_THREW, "the phase gave no ending"),

/// A message in the process's mailbox: an answer to a request of its, by the request's key.
pub const Mail = struct {
    key: []const u8,
    name: []const u8,
    payload: []const u8,

    /// Whether it says its request was cut off with nothing to give.
    pub fn interrupted(message: Mail) bool {
        return std.mem.eql(u8, message.name, Request.interrupted_name);
    }
};

/// The mail of `key` in the process's mailbox, as the last commit left it; null while none has come.
pub fn mailOf(phase: *Phase, key: []const u8) !?Mail {
    const path = try phase.mailPath(key);
    const entry = try phase.runtime.volume.stat(&phase.arena, path) orelse return null;
    const directory = entry.directory orelse return error.DamagedMail;
    return .{
        .key = key,
        .name = beak.labelOf(directory.*.labels, directory.*.label_count, h.BEAK_MAIL_KIND) orelse "",
        .payload = try phase.runtime.volume.readAll(&phase.arena, try beak.join(phase.arena, path, h.BEAK_PAYLOAD_NAME)),
    };
}

/// The mail of `key` taken out of the mailbox, with the phase's commit.
pub fn take(phase: *Phase, key: []const u8) !void {
    try phase.changes.delete(try phase.mailPath(key));
}

/// The directory of the mail of `key` in the process's mailbox, as a wait on it and others names it.
pub fn mailPath(phase: *Phase, key: []const u8) Allocator.Error![]const u8 {
    return std.mem.concat(phase.arena, u8, &.{ phase.path, "/", h.BEAK_MAIL_KIND, ":", key });
}

/// A request of `name` to the outside, keyed by `key`, with the phase's commit: `payload`, its handler's to read; null
/// for one that says no more than its name. Its answer comes as mail of the same key.
pub fn request(phase: *Phase, name: []const u8, key: []const u8, payload: anytype) !void {
    try phase.changes.request(phase.path, key, name, try phase.jsonOf(payload));
}

/// A fiber of the program `kind` started under the phase's process, keyed by `key`, from `input`; null for none.
pub fn start(phase: *Phase, key: []const u8, kind: []const u8, input: anytype) !void {
    const version = phase.runtime.versionOf(kind) orelse return error.NoSuchProgram;
    try phase.changes.start(phase.path, key, kind, version, try phase.jsonOf(input), "");
}

/// The checkpoint a phase that waits again keeps: the one it ran from.
pub const Kept = struct {};
pub const kept: Kept = .{};

/// `value` as the phase writes it, in its arena.
fn jsonOf(phase: *Phase, value: anytype) ![]const u8 {
    const T = @TypeOf(value);
    if (T == @TypeOf(null)) return "";
    if (T == Kept) return phase.arena.dupe(u8, phase.checkpoint);
    return foundation.json.encode(phase.arena, value);
}

/// A fiber of the program `kind` started in the directory `directory`, beside the phase's process rather than under
/// it, keyed by `key`, from `input`: one no fiber waits on, whose end, as a process with no parent's, goes in time.
pub fn startIn(phase: *Phase, directory: []const u8, key: []const u8, kind: []const u8, input: anytype) !void {
    const version = phase.runtime.versionOf(kind) orelse return error.NoSuchProgram;
    try phase.changes.start(directory, key, kind, version, try phase.jsonOf(input), "");
}

/// A new id, minted at the phase's time.
pub fn mint(phase: *Phase) ![]const u8 {
    return phase.arena.dupe(u8, &try phase.runtime.volume.mint(phase.time));
}

/// The fiber is runnable again, its next phase from `checkpoint`, on what this one commits — as a process yields.
pub fn next(phase: *Phase, checkpoint: anytype) !void {
    phase.ending = endingOf(h.BEAK_ENDING_NEXT, try phase.jsonOf(checkpoint));
}

/// What a fiber waits for, the first of it met ending the wait, as `poll` waits on descriptors and a timeout at once.
pub const Wait = struct {
    /// Processes, any of which ending ends the wait.
    exits: []const []const u8 = &.{},
    /// Directories, any of which changing from what the last commit left ends it — a name made, removed or relinked in
    /// it, or its labels — as a process that ends changes its own.
    changes: []const []const u8 = &.{},
    /// Keys of mail, any of which in the fiber's mailbox ends it — at once, where it is there already.
    mail: []const []const u8 = &.{},
    /// A directory the selector picks written, one it picked leaving it, or a deletion that can take what it picks.
    until: ?beak.Selector = null,
    /// The time it ends at the latest.
    at: ?i64 = null,
};

/// The fiber sleeps until the first of what `wait` names is met, then runs from `checkpoint`.
pub fn waitFor(phase: *Phase, checkpoint: anytype, wait: Wait) !void {
    const arena = phase.arena;
    const on = try arena.alloc(h.beak_bytes, wait.exits.len);
    for (wait.exits, on) |path, *each| each.* = beak.bytes(try arena.dupe(u8, path));
    const versions = try arena.alloc(h.beak_version, wait.changes.len + wait.mail.len);
    for (wait.changes, versions[0..wait.changes.len]) |path, *version| version.* = try phase.versionOf(path);
    // A mail's directory waited on as one not there, the fiber wakes once it is there.
    for (wait.mail, versions[wait.changes.len..]) |key, *version| version.* = .{ .path = beak.bytes(try phase.mailPath(key)), .changed_seq = beak.optional(null) };
    const until: ?*h.beak_selector = if (wait.until) |selector| until: {
        const made = try arena.create(h.beak_selector);
        made.* = try beak.selectorOf(arena, selector);
        break :until made;
    } else null;
    phase.ending = endingOf(h.BEAK_ENDING_WAIT, try phase.jsonOf(checkpoint));
    phase.ending.wait = .{ .on = on.ptr, .on_count = on.len, .on_change = versions.ptr, .on_change_count = versions.len, .until = until, .at = beak.optional(wait.at) };
}

/// The directory at `path` as it stands now, for a wait on its change: its seq null for not there.
fn versionOf(phase: *Phase, path: []const u8) !h.beak_version {
    const found = try phase.runtime.volume.stat(&phase.arena, path);
    const seq: ?i64 = if (found) |entry| (if (entry.directory) |directory| @intCast(directory.*.changed_seq) else null) else null;
    return .{ .path = beak.bytes(try phase.arena.dupe(u8, path)), .changed_seq = beak.optional(seq) };
}

/// The fiber sleeps until the mail of `key` is in its mailbox — at once, where it is there already — then runs from
/// `checkpoint`, as a receive of one type of message does: mail of any other key leaves it sleeping.
pub fn waitForMail(phase: *Phase, checkpoint: anytype, key: []const u8) !void {
    try phase.waitFor(checkpoint, .{ .mail = &.{key} });
}

/// The fiber sleeps until the process at `path` ends, then runs from `checkpoint`.
pub fn waitForExit(phase: *Phase, checkpoint: anytype, path: []const u8) !void {
    try phase.waitFor(checkpoint, .{ .exits = &.{path} });
}

/// The fiber sleeps until the directory at `path` changes from what the last commit left, then runs from `checkpoint`.
pub fn waitForChange(phase: *Phase, checkpoint: anytype, path: []const u8) !void {
    try phase.waitFor(checkpoint, .{ .changes = &.{path} });
}

/// The fiber sleeps until any of the directories at `paths` changes from what the last commit left, then runs from
/// `checkpoint`: as `poll` waits on many, the first to change ending the wait.
pub fn waitForAny(phase: *Phase, checkpoint: anytype, paths: []const []const u8) !void {
    try phase.waitFor(checkpoint, .{ .changes = paths });
}

/// The fiber sleeps until the time `at`, then runs from `checkpoint`.
pub fn waitUntil(phase: *Phase, checkpoint: anytype, at: i64) !void {
    try phase.waitFor(checkpoint, .{ .at = at });
}

/// The fiber ends, done, with `result`; null for none.
pub fn done(phase: *Phase, result: anytype) !void {
    phase.ending = endingOf(h.BEAK_ENDING_DONE, try phase.jsonOf(result));
}

/// The fiber ends, failed, for `reason`.
pub fn fail(phase: *Phase, reason: []const u8) !void {
    phase.ending = endingOf(h.BEAK_ENDING_FAIL, try phase.arena.dupe(u8, reason));
}

/// The fiber's stop handler ends it, stopped, with `result`; null for none.
pub fn stopped(phase: *Phase, result: anytype) !void {
    phase.ending = endingOf(h.BEAK_ENDING_STOPPED, try phase.jsonOf(result));
}

/// An ending of `kind` with `given`, which lives as long as the phase's arena.
pub fn endingOf(kind: h.beak_ending_type, given: []const u8) h.beak_ending {
    var ending = std.mem.zeroes(h.beak_ending);
    ending.type = kind;
    ending.has_bytes = true;
    ending.bytes = beak.bytes(given);
    return ending;
}
