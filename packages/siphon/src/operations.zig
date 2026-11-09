//! Operations done once: a client's request that makes or adds something carries an id of its own, as an idempotency key
//! does, and its record — what it did, on which thread, and what it gave — is kept a day in `siphon.operations/`, in
//! the commit that does it; the same request sent again within the day, as a client sends one again after its
//! connection was lost, is answered with what it gave, not done again.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const beak = @import("beak.zig");
const runtime_ = @import("runtime.zig");
const Runtime = runtime_.Runtime;
const Changes = runtime_.Changes;

/// How long an operation's id is kept, so one sent again within it is answered, not done again.
pub const retention_ms = 24 * std.time.ms_per_hour;

/// The directory of the operations done in the last day, each a file by its id.
const directory = "siphon.operations";

/// What an operation did, as its record holds it: its method, the thread it was done on — none for one done on none —
/// and what it gave.
pub const Done = struct { method: []const u8, thread: []const u8 = "", result: []const u8 };

/// The record of the operation `operation`, where it was done before as `method` — on the thread `tid`, where it names
/// one; `OperationReused` where its id was used by another; `InvalidOperation` for an id no file can be named by.
pub fn before(runtime: *Runtime, arena: Allocator, operation: []const u8, method: []const u8, tid: ?[]const u8) !?Done {
    if (operation.len == 0 or std.mem.indexOfAny(u8, operation, "/\x00") != null) return error.InvalidOperation;
    const path = try beak.join(arena, directory, operation);
    if (try runtime.volume.stat(&arena, path) == null) return null;
    const done = try foundation.json.decode(Done, arena, try runtime.volume.readAll(&arena, path));
    const same_thread = if (tid) |named| std.mem.eql(u8, done.thread, named) else true;
    if (!std.mem.eql(u8, done.method, method) or !same_thread) return error.OperationReused;
    return done;
}

/// The record of the operation `operation`, which did `done`, kept a day from `time`, with the commit of `changes`.
pub fn record(changes: *Changes, operation: []const u8, done: Done, time: i64) Allocator.Error!void {
    const path = try beak.join(changes.arena, directory, operation);
    try changes.mkdir(directory);
    try changes.write(path, try foundation.json.encode(changes.arena, done));
    try changes.expire(path, time + retention_ms);
}
