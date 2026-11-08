//! The changes of one commit to a volume, each built by what it does: what a phase gives back with its ending, or what
//! an operation commits. What a change names is copied into the arena, which lasts until the commit.
const Changes = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const beak = @import("../beak.zig");
const h = beak.h;

arena: Allocator,
list: std.ArrayList(h.beak_change) = .empty,

pub fn items(changes: *const Changes) []const h.beak_change {
    return changes.list.items;
}

/// The directory at `path` made, and none other: its parent must be there; one there is left as it is.
pub fn mkdir(changes: *Changes, path: []const u8) Allocator.Error!void {
    _ = try changes.added(h.BEAK_CHANGE_MKDIR, path);
}

/// The file at `path` given `bytes` whole, keeping its mode.
pub fn write(changes: *Changes, path: []const u8, bytes: []const u8) Allocator.Error!void {
    const made = try changes.added(h.BEAK_CHANGE_WRITE, path);
    made.value = try changes.copied(bytes);
}

/// `bytes` added to the end of the file at `path`, made where there is none; the file takes bytes at its end alone.
pub fn append(changes: *Changes, path: []const u8, bytes: []const u8) Allocator.Error!void {
    const made = try changes.added(h.BEAK_CHANGE_APPEND, path);
    made.value = try changes.copied(bytes);
    made.append_only = true;
}

/// The file at `path` sealed: it takes no change from then on.
pub fn seal(changes: *Changes, path: []const u8) Allocator.Error!void {
    _ = try changes.added(h.BEAK_CHANGE_SEAL, path);
}

/// The name at `path` deleted: a file at once, a directory with everything under it once nothing lives there.
pub fn delete(changes: *Changes, path: []const u8) Allocator.Error!void {
    _ = try changes.added(h.BEAK_CHANGE_DELETE, path);
}

/// The directory at `path` goes with all it holds, every process under it killed for `reason` as it goes, as rm -rf
/// takes a tree whose programs were killed first.
pub fn deleteKilling(changes: *Changes, path: []const u8, reason: []const u8) Allocator.Error!void {
    const made = try changes.added(h.BEAK_CHANGE_DELETE, path);
    made.signal = h.BEAK_SIGNAL_KILL;
    made.reason = try changes.copied(reason);
}

/// Charges `counters` to the live process at `path` and to every process above it, as cgroup v2 charges a cgroup and
/// its ancestors: a process's usage is its whole subtree's, live and ended.
pub fn charge(changes: *Changes, path: []const u8, counters: []const h.beak_counter) Allocator.Error!void {
    const given = try changes.arena.alloc(h.beak_counter, counters.len);
    for (counters, given) |each, *out| out.* = .{ .name = try changes.copied(beak.slice(each.name)), .value = each.value };
    const made = try changes.added(h.BEAK_CHANGE_CHARGE, path);
    made.usage = given.ptr;
    made.usage_count = given.len;
}

/// The name at `path` goes at the time `at`.
pub fn expire(changes: *Changes, path: []const u8, at: i64) Allocator.Error!void {
    const made = try changes.added(h.BEAK_CHANGE_EXPIRE, path);
    made.at = beak.optional(at);
}

/// The directory at `path` labelled `name` = `value`, as its kind's index finds it.
pub fn label(changes: *Changes, path: []const u8, name: []const u8, value: []const u8) Allocator.Error!void {
    const labels = try changes.arena.alloc(h.beak_name_change, 1);
    labels[0] = .{ .name = try changes.copied(name), .remove = false, .value = try changes.copied(value) };
    const made = try changes.added(h.BEAK_CHANGE_META, path);
    made.labels = labels.ptr;
    made.label_count = labels.len;
}

/// An annotation as a change gives it: set to its value, or removed where it has none.
pub const Annotation = struct { name: []const u8, value: ?[]const u8 };

/// The directory at `path` annotated as `annotations` say, in one change — each set to its value or removed: what it
/// holds of itself, which no index finds it by.
pub fn annotate(changes: *Changes, path: []const u8, annotations: []const Annotation) Allocator.Error!void {
    const given = try changes.arena.alloc(h.beak_name_change, annotations.len);
    for (annotations, given) |each, *out| {
        out.* = .{ .name = try changes.copied(each.name), .remove = each.value == null, .value = try changes.copied(each.value orelse "") };
    }
    const made = try changes.added(h.BEAK_CHANGE_META, path);
    made.annotations = given.ptr;
    made.annotation_count = given.len;
}

/// A fiber of the program `kind`, of `version`, started under the process or directory at `parent`, keyed by `key`,
/// from `input` and `checkpoint`.
pub fn start(changes: *Changes, parent: []const u8, key: []const u8, kind: []const u8, version: u32, input: []const u8, checkpoint: []const u8) Allocator.Error!void {
    const made = try changes.added(h.BEAK_CHANGE_START, parent);
    made.key = try changes.copied(key);
    made.kind = try changes.copied(kind);
    made.version = version;
    made.value = try changes.copied(input);
    made.checkpoint = try changes.copied(checkpoint);
}

/// A request of `name` the process at `process` makes of the outside, keyed by `key`: `payload`, its handler's to read.
pub fn request(changes: *Changes, process: []const u8, key: []const u8, name: []const u8, payload: []const u8) Allocator.Error!void {
    const made = try changes.added(h.BEAK_CHANGE_REQUEST, process);
    made.key = try changes.copied(key);
    made.name = try changes.copied(name);
    made.value = try changes.copied(payload);
}

/// Mail of `key` sent to the process at `process` that the commit `started` started: `name`, with `payload`.
pub fn send(changes: *Changes, process: []const u8, started: u64, key: []const u8, name: []const u8, payload: []const u8) Allocator.Error!void {
    const made = try changes.added(h.BEAK_CHANGE_SEND, process);
    made.started = beak.optional(@intCast(started));
    made.key = try changes.copied(key);
    made.name = try changes.copied(name);
    made.value = try changes.copied(payload);
}

/// The request of `key` the process at `process`, started by the commit `started`, made answered: `name`, with
/// `payload`, as mail of its key — refused where no request of that key waits, so a request has one answer.
pub fn answer(changes: *Changes, process: []const u8, started: u64, key: []const u8, name: []const u8, payload: []const u8) Allocator.Error!void {
    const made = try changes.added(h.BEAK_CHANGE_ANSWER, process);
    made.started = beak.optional(@intCast(started));
    made.key = try changes.copied(key);
    made.name = try changes.copied(name);
    made.value = try changes.copied(payload);
}

/// The process at `path`, and every one under it, asked to stop, for `reason`: their stop handlers run, their requests
/// are cut off.
pub fn terminate(changes: *Changes, path: []const u8, reason: []const u8) Allocator.Error!void {
    const made = try changes.added(h.BEAK_CHANGE_SIGNAL, path);
    made.signal = h.BEAK_SIGNAL_TERMINATE;
    made.reason = try changes.copied(reason);
}

/// The ended child process at `path` reaped: its directory goes, as a parent reaps a child it settled.
pub fn reap(changes: *Changes, path: []const u8) Allocator.Error!void {
    _ = try changes.added(h.BEAK_CHANGE_REAP, path);
}

/// A change of `kind` at `path`, its other fields zero, added.
fn added(changes: *Changes, kind: h.beak_change_type, path: []const u8) Allocator.Error!*h.beak_change {
    const made = try changes.list.addOne(changes.arena);
    made.* = std.mem.zeroes(h.beak_change);
    made.type = kind;
    made.path = try changes.copied(path);
    return made;
}

fn copied(changes: *Changes, text: []const u8) Allocator.Error!h.beak_bytes {
    return beak.bytes(try changes.arena.dupe(u8, text));
}
