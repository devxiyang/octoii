//! What a request's handler waits on for news of its own sources — a command it runs — as each part of a host waits on
//! a set of Beak's of its own: a stop wakes the set, so the wait ends at once, never a step at a time. The set is
//! opened as the handler first asks for it; a stop that comes before then is seen as the handler waits.
const Waits = @This();

const std = @import("std");
const beak = @import("../beak.zig");
const h = beak.h;

/// The set, once opened; 0 before.
set: std.atomic.Value(h.beak_handle) = .init(0),
/// Set as a stop comes, before the set is woken.
stopped: std.atomic.Value(bool) = .init(false),

/// The set the handler adds its sources to, opened as it is first asked for, by the handler alone.
pub fn eventSet(waits: *Waits) !h.beak_handle {
    const opened = waits.set.load(.seq_cst);
    if (opened != 0) return opened;
    var set: h.beak_handle = 0;
    try beak.check(h.beak_events_open(&set));
    waits.set.store(set, .seq_cst);
    return set;
}

/// Waits until news may have come of the set's sources, or `timeout_ms` passes; error.Canceled once a stop came, as
/// it comes. A stop either finds the set opened, and wakes it, or comes before it was, and is seen here, the two read
/// and written in one order.
pub fn untilNews(waits: *Waits, timeout_ms: u32) error{ Canceled, Unexpected }!void {
    const set = waits.eventSet() catch return error.Unexpected;
    if (waits.stopped.load(.seq_cst)) return error.Canceled;
    var ready = false;
    _ = h.beak_events_wait(set, timeout_ms, &ready);
    if (waits.stopped.load(.seq_cst)) return error.Canceled;
}

/// Wakes the wait going on, from any thread, as news of what it waits for came from elsewhere — the loop completing
/// what it does for the task; a wait not begun yet reads that news before it sleeps.
pub fn wake(waits: *Waits) void {
    const set = waits.set.load(.seq_cst);
    if (set != 0) _ = h.beak_events_wake(set);
}

/// Stops the waits, from any thread: the one going on ends at once, and every one after, in error.Canceled.
pub fn stop(waits: *Waits) void {
    waits.stopped.store(true, .seq_cst);
    const set = waits.set.load(.seq_cst);
    if (set != 0) _ = h.beak_events_wake(set);
}

/// Closes the set, where it was opened, once no wait is on it.
pub fn close(waits: *Waits) void {
    const set = waits.set.load(.seq_cst);
    if (set != 0) _ = h.beak_close(set);
}

test "a stop ends a wait at once, and every wait after it" {
    var waits: Waits = .{};
    defer waits.close();
    _ = try waits.eventSet();
    const Stopper = struct {
        fn run(stopping: *Waits) void {
            std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake) catch {};
            stopping.stop();
        }
    };
    var stopper = try std.testing.io.concurrent(Stopper.run, .{&waits});
    defer stopper.await(std.testing.io);
    try std.testing.expectError(error.Canceled, waits.untilNews(std.math.maxInt(u32)));
    try std.testing.expectError(error.Canceled, waits.untilNews(std.math.maxInt(u32)));
}

test "a stop before the set is opened is seen as the handler waits" {
    var waits: Waits = .{};
    defer waits.close();
    waits.stop();
    try std.testing.expectError(error.Canceled, waits.untilNews(std.math.maxInt(u32)));
}
