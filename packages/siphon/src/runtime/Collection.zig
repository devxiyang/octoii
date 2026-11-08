//! How the runtime's volume is collected, as Redis rewrites its append-only log: what the volume keeps grows with every
//! commit, live or not, and once it has grown past what it kept after the last collection by `growth_percent` — and
//! past `min_bytes` — a job collects it off the loop, and what it keeps then is the base the next is weighed against.
//! The loop weighs it as a pump tells of commits, a counter's read; one collection runs at a time.
const Collection = @This();

const std = @import("std");
const beak = @import("../beak.zig");
const Runtime = @import("Runtime.zig");
const Waits = @import("Waits.zig");

const log = std.log.scoped(.siphon);

options: Options,
/// What the volume kept after the last collection, or as it opened.
base: u64,
/// Whether a collection's job runs.
running: bool = false,

pub const Options = struct {
    /// What the volume keeps before it is ever collected, at least, as Redis's auto-aof-rewrite-min-size.
    min_bytes: u64 = 64 << 20,
    /// How far past its base, in percent of it, what the volume keeps grows before it is collected, as Redis's
    /// auto-aof-rewrite-percentage.
    growth_percent: u64 = 100,
};

/// Whether what the volume keeps, `usage`, has grown past where it is collected.
pub fn isDue(collection: *const Collection, usage: u64) bool {
    const past = collection.base + collection.base * collection.options.growth_percent / 100;
    return usage >= collection.options.min_bytes and usage >= past;
}

/// Weighs what the volume keeps, from the loop, and starts a collection where it is due and none runs; one that cannot
/// start is told, and weighed again at the next pump that tells of commits.
pub fn weigh(runtime: *Runtime) void {
    const collection = &runtime.collection;
    if (collection.running) return;
    const usage = runtime.volume.usage() catch |err| return log.warn("the volume's usage could not be read: {s}", .{@errorName(err)});
    if (!collection.isDue(usage)) return;
    const collecting = runtime.allocator.create(Collecting) catch return;
    collecting.* = .{ .runtime = runtime, .time = runtime.time, .before = usage };
    collection.running = true;
    runtime.spawn(.{ .context = collecting, .run = Collecting.run, .finish = Collecting.finish, .drop = Collecting.drop }) catch |err| {
        collection.running = false;
        log.warn("the volume could not be collected: {s}", .{@errorName(err)});
    };
}

/// A collection's job: the time it collects at, given by the loop, and what the volume kept before and after.
const Collecting = struct {
    runtime: *Runtime,
    time: i64,
    before: u64,
    collected: anyerror!beak.h.beak_collected = error.NotRun,
    after: u64 = 0,

    /// Collects the volume, in the job's task: it takes no commit meanwhile.
    fn run(context: *anyopaque, _: *Waits) void {
        const collecting: *Collecting = @ptrCast(@alignCast(context));
        const volume = collecting.runtime.volume;
        collecting.collected = volume.collect(collecting.time);
        collecting.after = volume.usage() catch collecting.before;
    }

    /// Takes what the volume keeps now as the base, on the loop, and tells what went.
    fn finish(context: *anyopaque) void {
        const collecting: *Collecting = @ptrCast(@alignCast(context));
        defer drop(context);
        const collection = &collecting.runtime.collection;
        collection.running = false;
        const collected = collecting.collected catch |err| {
            // The base moves on all the same, so a volume that cannot be collected is not asked again at every pump.
            collection.base = collecting.before;
            return log.warn("the volume could not be collected: {s}", .{@errorName(err)});
        };
        collection.base = collecting.after;
        log.info("collected the volume: {d} objects forgotten, {d} kept; it keeps {d} bytes, from {d}", .{ collected.forgotten, collected.kept, collecting.after, collecting.before });
    }

    fn drop(context: *anyopaque) void {
        const collecting: *Collecting = @ptrCast(@alignCast(context));
        collecting.runtime.allocator.destroy(collecting);
    }
};

test "a volume grown past its base is collected by a job off the loop, and what it keeps then is the next base" {
    const Changes = @import("Changes.zig");
    const runtime = try Runtime.open(std.testing.allocator, .{ .io = std.testing.io, .device = .memory }, .{ .collection = .{ .min_bytes = 4 << 10 } });
    defer runtime.close();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A file written again and again leaves what it held before for a collection to give back.
    const written = 64;
    for (0..written) |round| {
        var changes: Changes = .{ .arena = arena };
        try changes.write("notes", try std.fmt.allocPrint(arena, "{d:0>1024}", .{round}));
        _ = try runtime.commit(&changes);
        _ = try runtime.pump();
    }
    for (0..200) |_| {
        if (!runtime.collection.running) break;
        runtime.waitForNews(50);
        _ = try runtime.pump();
    } else return error.NeverCollected;
    try std.testing.expect(runtime.collection.base > 0);
    try std.testing.expect(try runtime.volume.usage() < written * 1024 / 2);
}

test "a volume is due for collection once it has grown past its base by the share given, and past the floor" {
    const collection: Collection = .{ .options = .{ .min_bytes = 100, .growth_percent = 100 }, .base = 80 };
    try std.testing.expect(!collection.isDue(99));
    try std.testing.expect(!collection.isDue(159));
    try std.testing.expect(collection.isDue(160));
    const fresh: Collection = .{ .options = .{ .min_bytes = 100, .growth_percent = 100 }, .base = 0 };
    try std.testing.expect(!fresh.isDue(99));
    try std.testing.expect(fresh.isDue(100));
}
