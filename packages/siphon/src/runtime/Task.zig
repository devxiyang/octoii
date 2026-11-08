//! A task of the runtime's: work done off the loop, in a task of its own on the io — acting on a fiber's request, or a
//! job the loop started — one kind whatever it runs, as Linux's tasks are. Its work sleeps on Beak's sources through
//! its waits, an interruptible sleep: a stop wakes it, as a signal wakes a task sleeping interruptibly, and the sleep
//! ends in error.Canceled. It is marked ended as its work returns, so the loop reaps it, as a parent reaps a child. A
//! stop from the loop cuts it off as a signal is sent, never waiting: a task of its own wakes its sleeps and cancels it,
//! and it is reaped once that is done. As the runtime closes it is stopped and waited for, as kthread_stop waits.
const Task = @This();

const std = @import("std");
const Runtime = @import("Runtime.zig");
const Waits = @import("Waits.zig");

runtime: *Runtime,
/// The task doing the work, and the one cutting it off, where a stop did: started by the loop, which alone touches the
/// two.
future: std.Io.Future(void) = undefined,
canceller: ?std.Io.Future(void) = null,
/// Set as the work returns, and as the task cutting it off ends, so the loop reaps it.
returned: std.atomic.Value(bool) = .init(false),
cancelled: std.atomic.Value(bool) = .init(false),
/// What the work sleeps on for news of its own sources, which a stop wakes.
waits: Waits = .{},

/// Starts `work`, called with `args`, in a task of its own, from the loop: marked ended as it returns, and the loop
/// woken to reap it.
pub fn start(task: *Task, comptime work: anytype, args: anytype) error{ConcurrencyUnavailable}!void {
    const Work = struct {
        fn run(running: *Task, given: @TypeOf(args)) void {
            @call(.auto, work, given);
            running.returned.store(true, .release);
            running.runtime.wake();
        }
    };
    task.future = try task.runtime.host.io.concurrent(Work.run, .{ task, args });
}

/// Cuts the task off, from the loop, as a signal is sent, never waiting: a task of its own wakes its sleeps and cancels
/// it, and the loop reaps it once that is done.
pub fn cut(task: *Task) error{ConcurrencyUnavailable}!void {
    task.canceller = try task.runtime.host.io.concurrent(cancel, .{task});
}

fn cancel(task: *Task) void {
    task.waits.stop();
    task.future.cancel(task.runtime.host.io);
    task.cancelled.store(true, .release);
    task.runtime.wake();
}

/// Whether the loop may reap the task: its work returned, or the task cutting it off ended, where one did.
pub fn ended(task: *const Task) bool {
    return if (task.canceller != null) task.cancelled.load(.acquire) else task.returned.load(.acquire);
}

/// Waits for what runs the task, once it ended: the task cutting it off, where one did, else its own.
pub fn join(task: *Task) void {
    const io = task.runtime.host.io;
    if (task.canceller) |*canceller| canceller.await(io) else task.future.await(io);
}

/// Stops the task and waits for it, as the runtime closes: its sleeps woken and it cancelled; one already cut off is
/// waited for as it is.
pub fn stop(task: *Task) void {
    const io = task.runtime.host.io;
    task.waits.stop();
    if (task.canceller) |*canceller| canceller.await(io) else task.future.cancel(io);
}

/// Lets go of what the task held, once it is done.
pub fn deinit(task: *Task) void {
    task.waits.close();
}
