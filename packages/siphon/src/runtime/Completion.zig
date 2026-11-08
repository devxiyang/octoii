//! What a task waits on while the loop does something for it, as Linux's wait_for_completion_interruptible: the task
//! posts work that names it, the loop does the work — at once, or as an answer it waits on comes — and completes it
//! with what came of it, waking the task's waits; a stop wakes them too, and the task gives up on it. Whichever of the
//! two is done with it second lets go of it, so neither touches it once the other has let go. What the work is given
//! and what comes of it live in its arena: the task writes it before it posts, the loop as it completes, the task reads
//! it once it is complete.
const Completion = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Waits = @import("Waits.zig");

arena_state: std.heap.ArenaAllocator,
/// The waits of the task that waits on it, which the loop wakes as it completes.
waits: *Waits,
state: std.atomic.Value(State) = .init(.pending),
/// What came of the work, in the arena, once it is complete.
outcome: Outcome = .{ .failure = "not complete" },

const State = enum(u8) { pending, complete, abandoned };

/// What came of the work: what it gave, or the words for why it failed.
pub const Outcome = union(enum) { result: []const u8, failure: []const u8 };

/// A completion the task whose waits are `waits` waits on.
pub fn create(allocator: Allocator, waits: *Waits) Allocator.Error!*Completion {
    const completion = try allocator.create(Completion);
    completion.* = .{ .arena_state = .init(allocator), .waits = waits };
    return completion;
}

/// Memory that lasts as long as the completion: what the work is given, and what comes of it.
pub fn arena(completion: *Completion) Allocator {
    return completion.arena_state.allocator();
}

/// Completes it, from the loop, with `outcome`, copied: the task woken, or, where it gave up on it, the completion let
/// go of. A copy there is no room for completes it as failed.
pub fn complete(completion: *Completion, outcome: Outcome) void {
    completion.outcome = switch (outcome) {
        .result => |result| if (completion.arena().dupe(u8, result)) |copy| .{ .result = copy } else |_| .{ .failure = "no room for what came of it" },
        .failure => |failure| if (completion.arena().dupe(u8, failure)) |copy| .{ .failure = copy } else |_| .{ .failure = "no room for why it failed" },
    };
    if (completion.state.cmpxchgStrong(.pending, .complete, .acq_rel, .acquire) != null) return completion.destroy();
    completion.waits.wake();
}

/// Waits for it, from the task, at most `timeout_ms`: what came of the work, which lasts until the completion is let
/// go of; error.TimedOut where it is not complete by then, error.Canceled as a stop comes.
pub fn wait(completion: *Completion, io: std.Io, timeout_ms: u32) error{ Canceled, TimedOut, Unexpected }!Outcome {
    // The set is opened before the state is read, so a completion that wakes no set, as none was open, is seen here.
    _ = completion.waits.eventSet() catch return error.Unexpected;
    const due = std.Io.Clock.awake.now(io).addDuration(.fromMilliseconds(timeout_ms));
    while (completion.state.load(.acquire) != .complete) {
        const left = std.Io.Clock.awake.now(io).durationTo(due).toMilliseconds();
        if (left <= 0) return error.TimedOut;
        try completion.waits.untilNews(@intCast(@min(left, std.math.maxInt(u32))));
    }
    return completion.outcome;
}

/// Lets go of one the loop was never given, from the task, as what it was to be given could not be made.
pub fn discard(completion: *Completion) void {
    completion.destroy();
}

/// Lets go of it, from the task, complete or not: one the loop has not completed yet is left for it to let go of.
pub fn release(completion: *Completion) void {
    if (completion.state.cmpxchgStrong(.pending, .abandoned, .acq_rel, .acquire) == null) return;
    completion.destroy();
}

fn destroy(completion: *Completion) void {
    const allocator = completion.arena_state.child_allocator;
    completion.arena_state.deinit();
    allocator.destroy(completion);
}

test "a task waits for what the loop completes, and the second to be done with it lets go of it" {
    var waits: Waits = .{};
    defer waits.close();
    const Loop = struct {
        fn run(completing: *Completion) void {
            std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
            completing.complete(.{ .result = "done" });
        }
    };
    const completion = try create(std.testing.allocator, &waits);
    var loop = try std.testing.io.concurrent(Loop.run, .{completion});
    const outcome = try completion.wait(std.testing.io, 5_000);
    loop.await(std.testing.io);
    try std.testing.expectEqualStrings("done", outcome.result);
    completion.release();

    // Given up on before it is complete, it is let go of as the loop completes it.
    const abandoned = try create(std.testing.allocator, &waits);
    try std.testing.expectError(error.TimedOut, abandoned.wait(std.testing.io, 1));
    abandoned.release();
    abandoned.complete(.{ .failure = "too late" });
}

test "a stop ends the wait at once" {
    var waits: Waits = .{};
    defer waits.close();
    const completion = try create(std.testing.allocator, &waits);
    defer completion.complete(.{ .result = "after the stop" });
    defer completion.release();
    waits.stop();
    try std.testing.expectError(error.Canceled, completion.wait(std.testing.io, 5_000));
}
