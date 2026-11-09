//! Going on at a time the person asked — when the quota its model's account used up is given again: a fiber beside the
//! thread's main fiber, of no turn, that sleeps till then, delivers the person's word to go on to the thread's inbox, as
//! `at` runs a job at its time, and ends; a turn begins with it. What the person sends meanwhile, or another model
//! they give the thread, ends it first, as they went on themselves.
const std = @import("std");
const foundation = @import("foundation");
const runtime_ = @import("../runtime.zig");
const Runtime = runtime_.Runtime;
const Phase = runtime_.Phase;
const threads = @import("../threads.zig");

/// What a resume is armed with: when it goes on, in milliseconds since the epoch.
const Armed = struct { at: i64 };

/// The person's word it goes on with.
pub const word = "Continue where you stopped: the account's limit is given again.";

pub fn register(runtime: *Runtime) !void {
    try runtime.register(.{ .kind = threads.resume_program, .phase = resuming });
}

/// Sleeps till the time armed, then delivers the word to go on, and ends.
fn resuming(_: ?*anyopaque, run: *Phase) anyerror!void {
    const armed = try foundation.json.decode(Armed, run.arena, run.input);
    if (run.time < armed.at) return run.waitUntil(Phase.kept, armed.at);
    const id = try run.mint();
    const input: threads.Input = .{ .message = .{ .role = .user, .content = .{ .text = word } } };
    try threads.inboxed(&run.changes, threads.threadOf(run.path), id, input, try std.mem.concat(run.arena, u8, &.{ "resumed-", id }));
    return run.done(null);
}
