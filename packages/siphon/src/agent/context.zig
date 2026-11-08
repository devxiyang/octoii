//! What fills a thread's window, as the person is shown it: the tokens its next request takes, as near as its log tells,
//! shared among what holds them — what Octoii tells the model of itself, the machine and the thread; the instructions;
//! the skills; the MCP servers' catalog; the tools' declarations; the recap of what came before; the person's messages;
//! the model's replies — its words, its thoughts and its calls; and what the calls gave. Each is estimated as `ai`
//! estimates items, as a request would send them, and the estimates scaled to the window's tokens: near, not exact, as
//! no tokenizer is run.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const estimate = vocabulary.estimate;
const runtime_ = @import("../runtime.zig");
const Runtime = runtime_.Runtime;
const threads = @import("../threads.zig");
const log = threads.log;
const Window = threads.Window;
const compaction = @import("compaction.zig");
const models = @import("models.zig");

/// What holds a share of a window.
pub const Part = enum { system, instructions, skills, catalog, tools, recap, messages, replies, results };

/// A part's share of a window, in tokens.
pub const Share = struct { part: Part, tokens: u64 };

/// What fills a window: its tokens, and each part's share of them — those that hold none left out.
pub const Composition = struct { tokens: u64, parts: []const Share };

/// What fills the window the log of the thread at `thread` ends in.
pub fn of(runtime: *const Runtime, arena: *const Allocator, thread: []const u8) !Composition {
    return compositionOf(arena.*, try Window.of(arena.*, try log.lines(runtime.volume, arena, thread)));
}

/// What fills `window`.
pub fn compositionOf(arena: Allocator, window: Window) !Composition {
    var estimated: std.EnumArray(Part, u64) = .initFill(0);
    for (window.told) |line| try estimateTold(arena, &estimated, line);
    if (window.compaction) |made| estimated.getPtr(.recap).* += estimate.text(try compaction.recapIn(arena, made));
    for (window.conversation) |line| {
        const kind = (try log.headOf(arena, line)).type;
        if (std.mem.eql(u8, kind, "system")) {
            try estimateTold(arena, &estimated, line);
            continue;
        }
        const part: Part = if (std.mem.eql(u8, kind, "input")) .messages else if (std.mem.eql(u8, kind, "reply")) .replies else if (std.mem.eql(u8, kind, "result")) .results else continue;
        var items: std.ArrayList(vocabulary.Item) = .empty;
        try models.appendItems(arena, &items, line);
        estimated.getPtr(part).* += estimate.items(items.items);
    }
    const tokens = try compaction.tokensOf(arena, window);
    var whole: u64 = 0;
    for (estimated.values) |each| whole += each;
    var shares: std.ArrayList(Share) = .empty;
    for (std.enums.values(Part)) |part| {
        const each = estimated.get(part);
        if (each > 0) try shares.append(arena, .{ .part = part, .tokens = each * tokens / whole });
    }
    return .{ .tokens = tokens, .parts = shares.items };
}

/// Adds what a system entry, its `line`, tells the model to `estimated`: each section to its part, the tools'
/// declarations to theirs.
fn estimateTold(arena: Allocator, estimated: *std.EnumArray(Part, u64), line: []const u8) !void {
    const entry = try foundation.json.decode(log.System, arena, line);
    for (entry.sections) |section| estimated.getPtr(partOf(section.name)).* += estimate.text(section.text orelse "");
    for (entry.tools) |tool| estimated.getPtr(.tools).* += estimate.text(try foundation.json.encode(arena, tool));
}

/// The part a system section of `name` holds a share of: what Octoii tells of itself, the machine and the thread, but
/// the instructions, the skills and the catalog.
fn partOf(name: []const u8) Part {
    const parts = [_]struct { []const u8, Part }{ .{ "instructions", .instructions }, .{ "skills", .skills }, .{ "catalog", .catalog } };
    for (parts) |each| if (std.mem.eql(u8, each[0], name)) return each[1];
    return .system;
}
