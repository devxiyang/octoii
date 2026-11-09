//! What the tests of every package lean on: allocation failures checked alike on every run.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Checks that `test_fn`, given an allocator and `extra_args`, frees what it took wherever an allocation fails on the
/// way, as `std.testing.checkAllAllocationFailures` does — over an allocator that never resizes in place, so a function
/// that grows an arena or a list makes the same allocations on every run, whatever the allocator beneath did before.
pub fn checkAllAllocationFailures(comptime test_fn: anytype, extra_args: anytype) !void {
    // A failing allocator whose first resize fails fails every one after: what grows is allocated anew and copied.
    var steady: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .resize_fail_index = 0 });
    return std.testing.checkAllAllocationFailures(steady.allocator(), test_fn, extra_args);
}

/// Grows a list a byte at a time, in an arena, with `allocator`: what would resize in place, were it let.
fn grow(allocator: Allocator, count: usize) !void {
    var arena_allocator: std.heap.ArenaAllocator = .init(allocator);
    defer arena_allocator.deinit();
    var list: std.ArrayList(u8) = .empty;
    for (0..count) |index| try list.append(arena_allocator.allocator(), @truncate(index));
}

test "a function that grows an arena makes the same allocations on every run, each failure freeing what came before" {
    try checkAllAllocationFailures(grow, .{100_000});
}
