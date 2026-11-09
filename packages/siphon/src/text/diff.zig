//! Line diffs: the shortest edit that turns one list of lines into another, by Myers' algorithm, the lines both start
//! and end with kept aside first; and the unified diff people and models read, `context_lines` unchanged lines around
//! each change.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// The unchanged lines a unified diff shows around each change.
pub const context_lines = 3;

/// The most edits the search for the shortest one tries; past them, what lies between the lines kept is removed and
/// added whole.
pub const edits_max = 1_000;

/// A run of an edit: lines both lists keep, lines the first alone has, or lines the second alone has.
pub const Run = struct { kind: enum { equal, delete, insert }, count: usize };

/// How two lines are compared.
pub const Same = *const fn (a: []const u8, b: []const u8) bool;

pub fn exactly(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// The runs that turn `before` into `after`, lines compared by `same`; none empty, no two alike side by side.
pub fn runsOf(arena: Allocator, before: []const []const u8, after: []const []const u8, same: Same) error{OutOfMemory}![]const Run {
    var start: usize = 0;
    while (start < before.len and start < after.len and same(before[start], after[start])) start += 1;
    var end: usize = 0;
    while (end < before.len - start and end < after.len - start and same(before[before.len - 1 - end], after[after.len - 1 - end])) end += 1;
    var runs: std.ArrayList(Run) = .empty;
    try runs.append(arena, .{ .kind = .equal, .count = start });
    const old = before[start .. before.len - end];
    const new = after[start .. after.len - end];
    const middle = if (old.len == 0 or new.len == 0) null else try shortestEdit(arena, old, new, same);
    if (middle) |found| try runs.appendSlice(arena, found) else {
        try runs.append(arena, .{ .kind = .delete, .count = old.len });
        try runs.append(arena, .{ .kind = .insert, .count = new.len });
    }
    try runs.append(arena, .{ .kind = .equal, .count = end });
    return joined(arena, runs.items);
}

/// How many lines an edit adds, and removes.
pub fn countsOf(runs: []const Run) struct { additions: usize, deletions: usize } {
    var additions: usize = 0;
    var deletions: usize = 0;
    for (runs) |run| switch (run.kind) {
        .insert => additions += run.count,
        .delete => deletions += run.count,
        .equal => {},
    };
    return .{ .additions = additions, .deletions = deletions };
}

/// The shortest edit from `before` to `after`, both not empty, by Myers' search: after each count of edits, the furthest
/// each diagonal reaches — `rows[d][k + d]` on diagonal `k` after `d` edits — till one reaches both ends; none past
/// `edits_max`.
fn shortestEdit(arena: Allocator, before: []const []const u8, after: []const []const u8, same: Same) error{OutOfMemory}!?[]const Run {
    const n: isize = @intCast(before.len);
    const m: isize = @intCast(after.len);
    var rows: std.ArrayList([]isize) = .empty;
    var d: isize = 0;
    while (d <= @min(n + m, edits_max)) : (d += 1) {
        const row = try arena.alloc(isize, @intCast(2 * d + 1));
        try rows.append(arena, row);
        var k = -d;
        while (k <= d) : (k += 2) {
            var x: isize = if (d == 0) 0 else if (cameDown(rows.items, d, k)) reach(rows.items, d - 1, k + 1) else reach(rows.items, d - 1, k - 1) + 1;
            var y = x - k;
            while (x < n and y < m and same(before[@intCast(x)], after[@intCast(y)])) {
                x += 1;
                y += 1;
            }
            row[@intCast(k + d)] = x;
            if (x >= n and y >= m) return try traced(arena, rows.items, n, m);
        }
    }
    return null;
}

/// How far diagonal `k` reached after `d` edits.
fn reach(rows: []const []isize, d: isize, k: isize) isize {
    return rows[@intCast(d)][@intCast(k + d)];
}

/// Whether the furthest way to diagonal `k` after `d` edits came down from diagonal `k + 1` — an insertion — rather
/// than across from `k - 1`, a deletion.
fn cameDown(rows: []const []isize, d: isize, k: isize) bool {
    if (k == -d) return true;
    if (k == d) return false;
    return reach(rows, d - 1, k - 1) < reach(rows, d - 1, k + 1);
}

/// The runs of the edit the search found, read back from both ends to the start.
fn traced(arena: Allocator, rows: []const []isize, n: isize, m: isize) error{OutOfMemory}![]const Run {
    var reversed: std.ArrayList(Run) = .empty;
    var x = n;
    var y = m;
    var d: isize = @intCast(rows.len - 1);
    while (d > 0) : (d -= 1) {
        const k = x - y;
        const down = cameDown(rows, d, k);
        const from_k = if (down) k + 1 else k - 1;
        const from_x = reach(rows, d - 1, from_k);
        const snake_start = if (down) from_x else from_x + 1;
        try reversed.append(arena, .{ .kind = .equal, .count = @intCast(x - snake_start) });
        try reversed.append(arena, .{ .kind = if (down) .insert else .delete, .count = 1 });
        x = from_x;
        y = from_x - from_k;
    }
    try reversed.append(arena, .{ .kind = .equal, .count = @intCast(x) });
    std.mem.reverse(Run, reversed.items);
    return reversed.items;
}

/// `runs` with the empty ones dropped and neighbours of one kind made one.
fn joined(arena: Allocator, runs: []const Run) error{OutOfMemory}![]const Run {
    var out: std.ArrayList(Run) = .empty;
    for (runs) |run| {
        if (run.count == 0) continue;
        if (out.items.len > 0 and out.items[out.items.len - 1].kind == run.kind) {
            out.items[out.items.len - 1].count += run.count;
        } else try out.append(arena, run);
    }
    return out.items;
}

/// A text's lines, each with its newline where it has one.
pub fn linesOf(arena: Allocator, text: []const u8) error{OutOfMemory}![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, start, '\n')) |newline| {
        try out.append(arena, text[start .. newline + 1]);
        start = newline + 1;
    }
    if (start < text.len) try out.append(arena, text[start..]);
    return out.items;
}

/// The unified diff from `before` to `after`, both named `name` — `before` from `/dev/null` where it is none, a file
/// made — with `context_lines` unchanged lines around each change and a line without its newline marked; empty where
/// the two are the same.
pub fn unified(arena: Allocator, before: ?[]const u8, after: []const u8, name: []const u8) error{OutOfMemory}![]const u8 {
    const old = try linesOf(arena, before orelse "");
    const new = try linesOf(arena, after);
    var body: std.Io.Writer.Allocating = .init(arena);
    try writeHunks(arena, &body.writer, try runsOf(arena, old, new, exactly), old, new);
    const hunks = body.written();
    if (hunks.len == 0) return "";
    return arena.print("--- {s}\n+++ {s}\n{s}", .{ if (before == null) "/dev/null" else name, name, hunks[0 .. hunks.len - 1] });
}

/// A hunk as it is gathered: where it starts in each text, from 0, how many lines of each it holds, and its lines.
const Hunk = struct { old_start: usize, new_start: usize, old_count: usize, new_count: usize, lines: std.Io.Writer.Allocating };

/// Writes the hunks of an edit: each change with the unchanged lines around it, changes nearer than twice the context
/// one hunk.
fn writeHunks(arena: Allocator, out: *std.Io.Writer, runs: []const Run, old: []const []const u8, new: []const []const u8) error{OutOfMemory}!void {
    var old_at: usize = 0;
    var new_at: usize = 0;
    var current: ?Hunk = null;
    for (runs, 0..) |run, index| {
        if (run.kind == .equal) {
            if (current) |*hunk| {
                const last = index == runs.len - 1;
                const tail = if (last or run.count > 2 * context_lines) @min(run.count, context_lines) else run.count;
                for (old[old_at..][0..tail]) |line| try writeLine(&hunk.lines.writer, ' ', line);
                hunk.old_count += tail;
                hunk.new_count += tail;
                if (tail < run.count) {
                    try writeHunk(out, hunk);
                    current = null;
                }
            }
            old_at += run.count;
            new_at += run.count;
            continue;
        }
        if (current == null) {
            const lead = @min(old_at, context_lines);
            current = .{ .old_start = old_at - lead, .new_start = new_at - lead, .old_count = lead, .new_count = lead, .lines = .init(arena) };
            for (old[old_at - lead .. old_at]) |line| try writeLine(&current.?.lines.writer, ' ', line);
        }
        const hunk = &current.?;
        if (run.kind == .delete) {
            for (old[old_at..][0..run.count]) |line| try writeLine(&hunk.lines.writer, '-', line);
            hunk.old_count += run.count;
            old_at += run.count;
        } else {
            for (new[new_at..][0..run.count]) |line| try writeLine(&hunk.lines.writer, '+', line);
            hunk.new_count += run.count;
            new_at += run.count;
        }
    }
    if (current) |*hunk| try writeHunk(out, hunk);
}

fn writeHunk(out: *std.Io.Writer, hunk: *Hunk) error{OutOfMemory}!void {
    out.writeAll("@@ -") catch return error.OutOfMemory;
    try writeRange(out, hunk.old_start, hunk.old_count);
    out.writeAll(" +") catch return error.OutOfMemory;
    try writeRange(out, hunk.new_start, hunk.new_count);
    out.print(" @@\n{s}", .{hunk.lines.written()}) catch return error.OutOfMemory;
}

/// A hunk's range as a unified diff writes it: its first line, from 1, and how many; an empty range names the line
/// before it.
fn writeRange(out: *std.Io.Writer, start: usize, count: usize) error{OutOfMemory}!void {
    const written = switch (count) {
        0 => out.print("{d},0", .{start}),
        1 => out.print("{d}", .{start + 1}),
        else => out.print("{d},{d}", .{ start + 1, count }),
    };
    written catch return error.OutOfMemory;
}

/// A line of a diff after its mark, its ending left out; one with no newline followed by a note that it has none.
fn writeLine(out: *std.Io.Writer, mark: u8, line: []const u8) error{OutOfMemory}!void {
    const ending: usize = if (std.mem.endsWith(u8, line, "\r\n")) 2 else if (std.mem.endsWith(u8, line, "\n")) 1 else 0;
    const text = line[0 .. line.len - ending];
    out.print("{c}{s}\n", .{ mark, text }) catch return error.OutOfMemory;
    if (!std.mem.endsWith(u8, line, "\n")) out.writeAll("\\ No newline at end of file\n") catch return error.OutOfMemory;
}

test "an edit between lines keeps their common start and end and finds the shortest edit between" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const runs = try runsOf(arena, &.{ "a", "b", "c", "d" }, &.{ "a", "x", "c", "d", "e" }, exactly);
    try std.testing.expectEqualSlices(Run, &.{
        .{ .kind = .equal, .count = 1 },
        .{ .kind = .delete, .count = 1 },
        .{ .kind = .insert, .count = 1 },
        .{ .kind = .equal, .count = 2 },
        .{ .kind = .insert, .count = 1 },
    }, runs);
    try std.testing.expectEqual(@as(usize, 2), countsOf(runs).additions);
    try std.testing.expectEqual(@as(usize, 1), countsOf(runs).deletions);
    // The shortest edit within: lines moved are found as kept, not rewritten whole.
    const within = try runsOf(arena, &.{ "s", "a", "b", "c", "e" }, &.{ "s", "b", "c", "x", "e" }, exactly);
    try std.testing.expectEqual(@as(usize, 1), countsOf(within).additions);
    try std.testing.expectEqual(@as(usize, 1), countsOf(within).deletions);
    try std.testing.expectEqualSlices(Run, &.{.{ .kind = .insert, .count = 2 }}, try runsOf(arena, &.{}, &.{ "a", "b" }, exactly));
}

test "a unified diff shows each change with its context, marks a missing newline, and names a new file's /dev/null" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    try std.testing.expectEqualStrings(
        \\--- f
        \\+++ f
        \\@@ -1,3 +1,3 @@
        \\ one
        \\-two
        \\+deux
        \\ three
    , try unified(arena, "one\ntwo\nthree\n", "one\ndeux\nthree\n", "f"));
    try std.testing.expectEqualStrings(
        \\--- /dev/null
        \\+++ g
        \\@@ -0,0 +1 @@
        \\+new
        \\\ No newline at end of file
    , try unified(arena, null, "new", "g"));
    try std.testing.expectEqualStrings("", try unified(arena, "same\n", "same\n", "h"));
    // Changes far apart are hunks of their own; a CRLF file's lines are shown without their `\r`.
    const far = try unified(arena, "1\r\n2\r\n3\r\n4\r\n5\r\n6\r\n7\r\n8\r\n9\r\n10\r\n", "one\r\n2\r\n3\r\n4\r\n5\r\n6\r\n7\r\n8\r\n9\r\nten\r\n", "f");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, far, "@@ -"));
    try std.testing.expect(std.mem.indexOfScalar(u8, far, '\r') == null);
}
