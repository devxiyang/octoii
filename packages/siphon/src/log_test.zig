//! A thread's log as its readers read it: a page at a time, each line once and in order, across its segments, going on
//! from where a reader stands — at a segment's start, its end, or where a line starts, and nowhere else.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Siphon = @import("Siphon.zig");
const Changes = @import("runtime.zig").Changes;
const threads = @import("threads.zig");
const log = @import("threads.zig").log;
const testing = @import("testing.zig");

/// The lines of the entries `first` up to `end`, each of its number, about `bytes` long.
pub fn linesOf(arena: Allocator, first: usize, end: usize, bytes: usize) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    for (first..end) |number| {
        try out.writer.print("{{\"id\":\"{d:0>6}\",\"type\":\"note\",\"text\":\"", .{number});
        try out.writer.splatByteAll('x', bytes);
        try out.writer.writeAll("\"}\n");
    }
    return out.written();
}

/// Begins a segment of the log of the thread at `thread` for each of `segments`, in order, holding its lines.
pub fn writeSegments(siphon: *Siphon, arena: Allocator, thread: []const u8, segments: []const []const u8) !void {
    var changes: Changes = .{ .arena = arena };
    for (segments) |lines| {
        // A segment is named by the entry that begins it, as the log's writer names it.
        const first = lines[0 .. std.mem.indexOfScalar(u8, lines, '\n') orelse lines.len];
        const name = try std.mem.concat(arena, u8, &.{ (try log.headOf(arena, first)).id, log.segment_extension });
        try changes.append(try log.segmentPath(arena, thread, name), lines);
    }
    _ = try siphon.runtime.commit(&changes);
}

test "a log is read a page at a time, each line once and in order, across its segments, a long line whole" {
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.open(&clock, .memory);
    defer siphon.close();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const thread = try threads.pathOf(arena, try threads.create(siphon.runtime, arena, .{}, "create"));
    const unbegun = try log.readFrom(siphon.runtime.volume, &arena, thread, null, 300);
    try std.testing.expect(unbegun.cursor == null and !unbegun.more);

    try writeSegments(siphon, arena, thread, &.{ try linesOf(arena, 0, 10, 50), try linesOf(arena, 10, 25, 50) });
    var cursor: ?log.Cursor = null;
    var next: usize = 0;
    var pages: usize = 0;
    while (true) : (pages += 1) {
        const read = try log.readFrom(siphon.runtime.volume, &arena, thread, cursor, 300);
        for (read.lines) |line| {
            try std.testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{d:0>6}", .{next}), (try log.headOf(arena, line)).id);
            next += 1;
        }
        cursor = read.cursor;
        if (!read.more) break;
    }
    try std.testing.expectEqual(@as(usize, 25), next);
    try std.testing.expect(pages > 2);
    try std.testing.expectEqual(@as(usize, 0), (try log.readFrom(siphon.runtime.volume, &arena, thread, cursor, 300)).lines.len);

    // A line longer than a page comes whole, in a page of its own.
    var changes: Changes = .{ .arena = arena };
    try changes.append(try log.segmentPath(arena, thread, cursor.?.segment), try linesOf(arena, 25, 26, 1000));
    _ = try siphon.runtime.commit(&changes);
    const long = try log.readFrom(siphon.runtime.volume, &arena, thread, cursor, 300);
    try std.testing.expectEqual(@as(usize, 1), long.lines.len);
    try std.testing.expect(!long.more);
}

test "a log is read back a page at a time, from its end or from an entry, across its segments, to its start" {
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.open(&clock, .memory);
    defer siphon.close();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tid = try threads.create(siphon.runtime, arena, .{}, "create");
    const thread = try threads.pathOf(arena, tid);
    try writeSegments(siphon, arena, thread, &.{ try linesOf(arena, 0, 100, 2000), try linesOf(arena, 100, 200, 2000), try linesOf(arena, 200, 250, 2000) });

    const latest = try log.readBefore(siphon.runtime.volume, &arena, thread, null, 10);
    try expectIds(arena, latest.lines, 240, 250);
    try std.testing.expect(!latest.complete);
    // Where the log ends as it was read: a reader reads on from there.
    const read = try log.readFrom(siphon.runtime.volume, &arena, thread, latest.end, 1 << 20);
    try std.testing.expectEqual(@as(usize, 0), read.lines.len);

    // From an entry, back across a segment's start; to the log's start, all it holds.
    try expectIds(arena, (try log.readBefore(siphon.runtime.volume, &arena, thread, "000105", 10)).lines, 95, 105);
    const first = try log.readBefore(siphon.runtime.volume, &arena, thread, "000005", 10);
    try expectIds(arena, first.lines, 0, 5);
    try std.testing.expect(first.complete);
    const whole = try log.readBefore(siphon.runtime.volume, &arena, thread, null, 1000);
    try expectIds(arena, whole.lines, 0, 250);
    try std.testing.expect(whole.complete);
    try std.testing.expectError(error.NoSuchEntry, log.readBefore(siphon.runtime.volume, &arena, thread, "nope", 5));
}

/// That `lines` hold the entries of the ids `first` to `end`, in order.
fn expectIds(arena: Allocator, lines: []const []const u8, first: usize, end: usize) !void {
    try std.testing.expectEqual(end - first, lines.len);
    for (lines, first..) |line, number| try std.testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{d:0>6}", .{number}), (try log.headOf(arena, line)).id);
}

test "a reader stands at a segment's start, its end, or where a line starts, and nowhere else" {
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.open(&clock, .memory);
    defer siphon.close();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const thread = try threads.pathOf(arena, try threads.create(siphon.runtime, arena, .{}, "create"));
    const lines = try linesOf(arena, 0, 3, 10);
    try writeSegments(siphon, arena, thread, &.{lines});
    const segment = (try log.lastSegment(siphon.runtime.volume, &arena, thread)).?;
    const line = std.mem.indexOfScalar(u8, lines, '\n').? + 1;
    for ([_]u64{ 0, line, lines.len }) |offset| try std.testing.expect(try log.holds(siphon.runtime.volume, &arena, thread, .{ .segment = segment.name, .offset = offset }));
    for ([_]u64{ 5, lines.len + 1 }) |offset| try std.testing.expect(!try log.holds(siphon.runtime.volume, &arena, thread, .{ .segment = segment.name, .offset = offset }));
    for ([_][]const u8{ "none.jsonl", "../thread.json", "" }) |name| try std.testing.expect(!try log.holds(siphon.runtime.volume, &arena, thread, .{ .segment = name, .offset = 0 }));
}
