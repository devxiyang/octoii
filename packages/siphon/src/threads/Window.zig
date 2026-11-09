//! A window of a thread's conversation: what its model is sent, from the last compaction on, as the log holds it — the
//! system entries the window begins with; the compaction's recap, which stands for every entry before those it keeps;
//! the input it keeps and the entries it keeps after it, as they stand before it; then every entry after the window's
//! system entries — each of them an entry the model is sent: never a failure, which the log keeps for the record, nor a
//! turn's end but one the person stopped, which tells the model that what it was doing was stopped, not finished. The
//! whole log where nothing was compacted. And how the window is asked: the effort the configurations before its first
//! reply set; one after it is in its conversation, a change where it stands. What a window begins with is never
//! changed within it, so a provider's cache of it holds.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const log = @import("log.zig");
const beak = @import("../beak.zig");

const ReasoningEffort = vocabulary.items.ReasoningEffort;

pub const Window = @This();

/// The system entries the window begins with: what the model is told before any input of the window.
told: []const []const u8,
/// The compaction the window begins at; none for the window the log begins.
compaction: ?log.Compaction = null,
/// The rest, in the order the model is sent it: the input the compaction keeps and the entries it keeps from its
/// `from` on, as they stand before it, but their system entries, which the window's own stand for; then every entry
/// after the window's beginning.
conversation: []const []const u8,
/// How many entries the conversation begins with that the compaction carried from before it: each was sent in an
/// earlier window, so what a reply among them says of its request is of that window.
carried: usize = 0,
/// How hard its model reasons as the window is asked: as the last configuration before the window's first reply set
/// it; none where none did.
effort: ?ReasoningEffort = null,
/// Where in the conversation the window's first reply of its own stands, its length where none came yet: a
/// configuration before it is how the window is asked, never sent where it stands.
answered: usize = 0,
/// The effort the log's last configuration set, the window's or after it; none where none did.
effort_set: ?ReasoningEffort = null,

/// The annotation on a thread's directory that holds where its window begins in its log — the entry its compaction keeps
/// first, as JSON — set in the commit that appends the compaction, so the window is read from there and the log before
/// it never; none for a log no compaction cut, which is read whole.
pub const from_annotation = "siphon.window_from";

/// The window the log of the thread at `thread` ends in, read from where the thread's directory says it begins.
pub fn read(volume: beak.Volume, arena: *const Allocator, thread: []const u8) !Window {
    const entry = try volume.stat(arena, thread) orelse return error.NoSuchThread;
    const from: ?log.Cursor = if (beak.annotationOf(entry, from_annotation)) |text| try foundation.json.decode(log.Cursor, arena.*, text) else null;
    return of(arena.*, (try log.readFrom(volume, arena, thread, from, std.math.maxInt(u64))).lines);
}

/// The window the log's `lines` end in.
pub fn of(arena: Allocator, lines: []const []const u8) !Window {
    var at = lines.len;
    const start = while (at > 0) {
        at -= 1;
        if (try isOf(arena, lines[at], "compaction")) break at;
    } else null;
    const after = if (start) |cut| lines[cut + 1 ..] else lines;
    var leading: usize = 0;
    while (leading < after.len and try isOf(arena, after[leading], "system")) leading += 1;
    var conversation: std.ArrayList([]const u8) = .empty;
    var compaction: ?log.Compaction = null;
    if (start) |cut| {
        const made = try foundation.json.decode(log.Compaction, arena, lines[cut]);
        const before = lines[0..cut];
        const kept = try indexOf(arena, before, made.kept) orelse return error.KeptGone;
        const from = try indexOf(arena, before, made.from) orelse return error.KeptGone;
        if (kept != from) try conversation.append(arena, before[kept]);
        for (before[from..]) |line| {
            // How the window is asked holds what a configuration carried set.
            if (try isOf(arena, line, "system") or try isOf(arena, line, "configuration") or !try isSent(arena, line)) continue;
            try conversation.append(arena, line);
        }
        compaction = made;
    }
    const carried = conversation.items.len;
    var answered: ?usize = null;
    for (after[leading..]) |line| {
        if (!try isSent(arena, line)) continue;
        if (answered == null and try isOf(arena, line, "reply")) answered = conversation.items.len;
        try conversation.append(arena, line);
    }
    const first = if (answered) |index| indexInLines(lines, conversation.items[index]) else lines.len;
    return .{
        .told = after[0..leading],
        .compaction = compaction,
        .conversation = conversation.items,
        .carried = carried,
        .effort = try effortIn(arena, lines[0..first]),
        .answered = answered orelse conversation.items.len,
        .effort_set = try effortIn(arena, lines),
    };
}

/// The effort the last configuration among `lines` set; none where none did.
fn effortIn(arena: Allocator, lines: []const []const u8) !?ReasoningEffort {
    var at = lines.len;
    while (at > 0) {
        at -= 1;
        if (try isOf(arena, lines[at], "configuration")) return (try foundation.json.decode(log.Configuration, arena, lines[at])).effort;
    }
    return null;
}

/// Where `line`, one of `lines` itself, stands among them.
fn indexInLines(lines: []const []const u8, line: []const u8) usize {
    for (lines, 0..) |each, index| if (each.ptr == line.ptr) return index;
    return lines.len;
}

/// Whether the entry `line` is one a model is sent where it stands in a conversation: what it is told, how it is
/// asked, an input, a reply, a result of a call of its own — none made under another, which the program that made it
/// read — and the end of a turn the person stopped.
fn isSent(arena: Allocator, line: []const u8) !bool {
    const head = try log.headOf(arena, line);
    if (head.under != null) return false;
    const kind = head.type;
    for ([_][]const u8{ "system", "configuration", "input", "reply", "result" }) |sent| if (std.mem.eql(u8, kind, sent)) return true;
    if (!std.mem.eql(u8, kind, "turn-end")) return false;
    return (try foundation.json.decode(log.TurnEnd, arena, line)).outcome == .stopped;
}

/// Whether the entry `line` is of the type `kind`.
fn isOf(arena: Allocator, line: []const u8, kind: []const u8) !bool {
    return std.mem.eql(u8, (try log.headOf(arena, line)).type, kind);
}

/// Where among `lines` the entry of `id` stands; null where none is.
fn indexOf(arena: Allocator, lines: []const []const u8, id: []const u8) !?usize {
    for (lines, 0..) |line, index| if (std.mem.eql(u8, (try log.headOf(arena, line)).id, id)) return index;
    return null;
}

test "a window begins at the last compaction: what it is told, its recap, what it keeps, then what came after" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const lines = [_][]const u8{
        \\{"id":"1","type":"system","request":"q1","sections":[{"name":"base","text":"b"}]}
        ,
        \\{"id":"2","type":"input","delivery_id":"d","actor":"person","message":{"role":"user","content":"one"}}
        ,
        \\{"id":"3","type":"turn-end","outcome":"replied"}
        ,
        \\{"id":"4","type":"system","request":"q4","sections":[{"name":"environment","text":"e2"}]}
        ,
        \\{"id":"5","type":"input","delivery_id":"d","actor":"person","message":{"role":"user","content":"two"}}
        ,
        \\{"id":"6","type":"compaction","request":"q6","response":{"id":"r","status":"completed","output":[]},"kept":"5","from":"5"}
        ,
        \\{"id":"7","type":"system","request":"q7","sections":[{"name":"base","text":"b"},{"name":"environment","text":"e2"}]}
        ,
        \\{"id":"8","type":"input","delivery_id":"d","actor":"person","message":{"role":"user","content":"three"}}
        ,
    };
    const whole = try of(arena, lines[0..5]);
    try std.testing.expectEqual(@as(usize, 1), whole.told.len);
    try std.testing.expect(whole.compaction == null);
    // The turn's end is kept for the record, never sent.
    try std.testing.expectEqual(@as(usize, 3), whole.conversation.len);
    try std.testing.expectEqual(@as(usize, 0), whole.carried);

    const window = try of(arena, &lines);
    try std.testing.expectEqualStrings("7", (try log.headOf(arena, window.told[0])).id);
    try std.testing.expectEqualStrings("q6", window.compaction.?.request);
    try std.testing.expectEqual(@as(usize, 2), window.conversation.len);
    try std.testing.expectEqual(@as(usize, 1), window.carried);
    try std.testing.expectEqualStrings("5", (try log.headOf(arena, window.conversation[0])).id);
    try std.testing.expectEqualStrings("8", (try log.headOf(arena, window.conversation[1])).id);
}

test "a turn the person stopped is sent with its end, so its model knows its work was stopped; another turn's end is not" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const lines = [_][]const u8{
        \\{"id":"1","type":"input","delivery_id":"d","actor":"person","message":{"role":"user","content":"one"}}
        ,
        \\{"id":"2","type":"turn-end","outcome":"stopped","reason":"stopped"}
        ,
        \\{"id":"3","type":"input","delivery_id":"d","actor":"person","message":{"role":"user","content":"two"}}
        ,
        \\{"id":"4","type":"turn-end","outcome":"failed","reason":"no model"}
        ,
    };
    const window = try of(arena, &lines);
    try std.testing.expectEqual(@as(usize, 3), window.conversation.len);
    try std.testing.expectEqualStrings("2", (try log.headOf(arena, window.conversation[1])).id);
}

test "a window cut within a turn keeps the input that began it, then the entries from where the cut fell" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const lines = [_][]const u8{
        \\{"id":"1","type":"system","request":"q1","sections":[{"name":"base","text":"b"}]}
        ,
        \\{"id":"2","type":"input","delivery_id":"d","actor":"person","message":{"role":"user","content":"fix it"}}
        ,
        \\{"id":"3","type":"reply","request":"q3","response":{"id":"r","status":"completed","output":[]}}
        ,
        \\{"id":"4","type":"result","status":"ok","call_output":{"type":"function_call_output","call_id":"c","output":"x"}}
        ,
        \\{"id":"5","type":"reply","request":"q5","response":{"id":"r","status":"completed","output":[]}}
        ,
        \\{"id":"6","type":"compaction","request":"q6","response":{"id":"r","status":"completed","output":[]},"kept":"2","from":"5"}
        ,
        \\{"id":"7","type":"system","request":"q7","sections":[{"name":"base","text":"b"}]}
        ,
    };
    const window = try of(arena, &lines);
    try std.testing.expectEqual(@as(usize, 2), window.conversation.len);
    try std.testing.expectEqual(@as(usize, 2), window.carried);
    try std.testing.expectEqualStrings("2", (try log.headOf(arena, window.conversation[0])).id);
    try std.testing.expectEqualStrings("5", (try log.headOf(arena, window.conversation[1])).id);
}
