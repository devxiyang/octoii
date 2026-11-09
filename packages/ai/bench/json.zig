//! Measures JSON as Octoii writes and reads it: a thread's items — messages, calls and their outputs, reasoning —
//! encoded and decoded one by one, as a log holds them, whole and small; a stream's events, as a model's answer
//! arrives; and one large string, as a file's text or a body crosses a channel. Each is timed over rounds enough to
//! stand above the clock's grain, and printed in MiB a second. `zig build bench -Doptimize=ReleaseSafe` runs it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const Item = vocabulary.items.Item;
const Event = vocabulary.events.ResponseStreamEvent;

/// How many items a sample thread holds.
const items_count = 2000;
/// How long the large string is.
const string_bytes = 32 * 1024 * 1024;
/// How long each measure runs at least, in nanoseconds.
const measure_ns = 1_000_000_000;

pub fn main(init: std.process.Init) !void {
    var arena_allocator: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var buffer: [1024]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(init.io, &buffer);
    const writer = &out.interface;

    inline for (.{ .{ "items", sampleItems }, .{ "small items", smallItems } }) |sample| {
        const items = try sample[1](arena);
        const lines = try linesOf(arena, Item, items);
        try report(writer, sample[0] ++ ", encoded", bytesOf(lines), try timed(init.io, init.gpa, Encode(Item){ .values = items }));
        try report(writer, sample[0] ++ ", decoded", bytesOf(lines), try timed(init.io, init.gpa, Decode(Item){ .lines = lines }));
    }
    const events = try sampleEvents(arena);
    const event_lines = try linesOf(arena, Event, events);
    try report(writer, "stream events, decoded", bytesOf(event_lines), try timed(init.io, init.gpa, Decode(Event){ .lines = event_lines }));

    const Text = struct { text: []const u8 };
    const text: Text = .{ .text = try sampleText(arena) };
    const text_line = try foundation.json.encode(arena, text);
    try report(writer, "a large string, encoded", text_line.len, try timed(init.io, init.gpa, Encode(Text){ .values = &.{text} }));
    try report(writer, "a large string, decoded", text_line.len, try timed(init.io, init.gpa, Decode(Text){ .lines = &.{text_line} }));
    try writer.flush();
}

/// A thread's items: a user's message, then rounds of reasoning, calls of the tools and their outputs, each answered.
fn sampleItems(arena: Allocator) ![]const Item {
    const items = try arena.alloc(Item, items_count);
    const output = try repeated(arena, "drwxr-xr-x  12 octoii  staff   384 Nov 10 02:00 src\n", 40);
    for (items, 0..) |*item, index| {
        const id = try arena.print("call_{d}", .{index / 4});
        item.* = switch (index % 4) {
            0 => .{ .reasoning = .{ .id = try arena.print("rs_{d}", .{index}), .summary = &.{.{ .text = "The listing first, then the file the question names." }}, .encrypted_content = try repeated(arena, "gAAAAABpZ", 120) } },
            1 => .{ .function_call = .{ .call_id = id, .name = "bash", .arguments = "{\"command\":\"ls -la src && cat src/part1.ts\",\"timeout\":120}" } },
            2 => .{ .function_call_output = .{ .call_id = id, .output = .{ .text = output } } },
            else => .{ .output_message = .{ .content = .{ .parts = &.{.{ .output_text = .{ .text = "The folder holds three parts, each exporting one function that returns its number." } }} } } },
        };
    }
    return items;
}

/// A thread's items as a short exchange makes them: brief messages and calls, a line of output each.
fn smallItems(arena: Allocator) ![]const Item {
    const items = try arena.alloc(Item, items_count);
    for (items, 0..) |*item, index| {
        const id = try arena.print("call_{d}", .{index / 4});
        item.* = switch (index % 4) {
            0 => .{ .input_message = .{ .role = .user, .content = .{ .parts = &.{.{ .input_text = .{ .text = "What is in src?" } }} } } },
            1 => .{ .function_call = .{ .call_id = id, .name = "bash", .arguments = "{\"command\":\"ls src\"}" } },
            2 => .{ .function_call_output = .{ .call_id = id, .output = .{ .text = "part1.ts\npart2.ts\n" } } },
            else => .{ .output_message = .{ .content = .{ .parts = &.{.{ .output_text = .{ .text = "Two parts." } }} } } },
        };
    }
    return items;
}

/// A stream's events as an answer arrives: deltas of its text, a few words each.
fn sampleEvents(arena: Allocator) ![]const Event {
    const events = try arena.alloc(Event, items_count * 4);
    for (events, 0..) |*event, index| {
        event.* = .{ .output_text_delta = .{ .item_id = "msg_0ec6957d7640869e016af104e1db5887", .output_index = 0, .sequence_number = index, .content_index = 0, .delta = " a few words" } };
    }
    return events;
}

/// `values`, each encoded, as the lines of a log.
fn linesOf(arena: Allocator, comptime T: type, values: []const T) ![]const []const u8 {
    const lines = try arena.alloc([]const u8, values.len);
    for (values, lines) |value, *line| line.* = try foundation.json.encode(arena, value);
    return lines;
}

fn bytesOf(lines: []const []const u8) usize {
    var bytes: usize = 0;
    for (lines) |line| bytes += line.len;
    return bytes;
}

/// Text as a file holds it: lines of code, with the quotes, backslashes and tabs a string escapes.
fn sampleText(arena: Allocator) ![]const u8 {
    const line = "\tconst message = \"a \\\"quoted\\\" word\"; // and a comment, long enough to be a line of code as written\n";
    return repeated(arena, line, string_bytes / line.len);
}

fn repeated(arena: Allocator, text: []const u8, times: usize) ![]const u8 {
    const out = try arena.alloc(u8, text.len * times);
    for (0..times) |index| @memcpy(out[index * text.len ..][0..text.len], text);
    return out;
}

/// Encodes each value, as a log's lines are written.
fn Encode(comptime T: type) type {
    return struct {
        values: []const T,
        fn run(work: @This(), arena: Allocator) !void {
            for (work.values) |value| std.mem.doNotOptimizeAway(try foundation.json.encode(arena, value));
        }
    };
}

/// Decodes each line, as a log's lines are read.
fn Decode(comptime T: type) type {
    return struct {
        lines: []const []const u8,
        fn run(work: @This(), arena: Allocator) !void {
            for (work.lines) |line| std.mem.doNotOptimizeAway(try foundation.json.decode(T, arena, line));
        }
    };
}

/// The nanoseconds `work` takes a round, at best of the rounds run within `measure_ns`, each in an arena kept warm.
fn timed(io: Io, gpa: Allocator, work: anytype) !u64 {
    var arena_allocator: std.heap.ArenaAllocator = .init(gpa);
    defer arena_allocator.deinit();
    var best: u64 = std.math.maxInt(u64);
    var spent: u64 = 0;
    var rounds: usize = 0;
    while (spent < measure_ns or rounds < 3) : (rounds += 1) {
        _ = arena_allocator.reset(.retain_capacity);
        const start: Io.Timestamp = .now(io, .awake);
        try work.run(arena_allocator.allocator());
        const took: u64 = @intCast(start.untilNow(io, .awake).toNanoseconds());
        best = @min(best, took);
        spent += took;
    }
    return best;
}

fn report(writer: *Io.Writer, what: []const u8, bytes: usize, ns: u64) !void {
    const mib = @as(f64, @floatFromInt(bytes)) / (1024 * 1024);
    const seconds = @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
    try writer.print("{s:<26} {d:>8.2} MiB in {d:>8.3} ms: {d:>8.1} MiB/s\n", .{ what, mib, seconds * 1000, mib / seconds });
}
