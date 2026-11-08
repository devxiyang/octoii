//! A call judged by a second model, as a thread in auto lets what would ask go ahead: a durable `review` request the
//! call's fiber makes — the model the person named, and the call as the model made it — which what serves it answers
//! with a verdict: let go ahead, or blocked and why, and what judging it used. A thread keeps count of the calls blocked
//! — in a row, and in all — as annotations of its directory; past three in a row or twenty in all, a call blocked asks
//! the person instead, as a person is asked once a judge keeps refusing.
const std = @import("std");
const threads = @import("../threads.zig");

/// The name of a review's request.
pub const request_name = "review";

/// What a review asks: the thread the call is made in, by its id, the model that judges it, and the call as the
/// thread's model made it.
pub const Asked = struct { thread: []const u8, model: []const u8, tool: []const u8, arguments: []const u8 };

/// What a review answers: whether the call may go ahead; why not, where it may not; and what judging it used.
pub const Verdict = struct { allow: bool, reason: []const u8 = "", usage: ?threads.Usage = null };

/// The annotations a thread keeps its blocked calls' counts in: those in a row, and all of them.
pub const blocked_in_a_row = "siphon.review.blocked_in_a_row";
pub const blocked_in_all = "siphon.review.blocked_in_all";

/// How many calls blocked in a row, and in all, a thread takes before a blocked call asks the person.
pub const in_a_row_max = 3;
pub const in_all_max = 20;

/// What the model is told of a call blocked: why, and how to go on.
pub fn blockedNote(arena: std.mem.Allocator, reason: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "a second model judged this call and blocked it: {s} — find a safer way within what the person asked, or ask them; do not work around the block", .{reason});
}
