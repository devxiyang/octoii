//! A thread's log: JSON Lines in segments under its `log/`, each segment named by the id of the entry that begins it,
//! as a log's segment is named by its first offset, so the names sort in the order the segments began, and only the
//! last is appended to, as Beak's append-only file; it is sealed as the next begins, past 32 MB. An entry is one line:
//! its `id`, minted as it is appended, which holds the time it was; its `type`; and its fields, in whole words, the
//! vocabulary's objects as they are. Entries are appended one at a time, each once, so ids rise along the log, and an
//! entry is in the last segment named at most its id.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const beak = @import("../beak.zig");
const Phase = @import("../runtime.zig").Phase;

/// Past it, the next entry begins a segment of its own.
pub const segment_bytes_max = 32 << 20;

/// What a segment's name ends in, after the id of the entry that begins it.
pub const segment_extension = ".jsonl";

/// What the model is told of itself and of where it works, where it changed before a turn: each section by its name,
/// with the text the model is sent of it, as it is sent — or none, a section no longer told; and, in the entry that
/// begins a window of the conversation, the tools the window declares, as they are declared.
pub const System = struct {
    id: []const u8,
    type: enum { system } = .system,
    /// The context request it was gathered by, by its key.
    request: []const u8,
    sections: []const Section = &.{},
    tools: []const vocabulary.Tool = &.{},
};

pub const Section = struct { name: []const u8, text: ?[]const u8 };

/// Where the conversation grew past what its model takes: the recap the model wrote of everything before the entry
/// `from` but the input `kept`, the latest the person gave before it — `from` itself where the cut falls at an input —
/// as its model request of `request` answered it, its response as it came; and from here on a window of its own, which
/// begins with what the model is told, gathered anew, then the recap, then the input as the person gave it and the
/// entries from `from` on as they stand, nothing copied.
pub const Compaction = struct {
    id: []const u8,
    type: enum { compaction } = .compaction,
    request: []const u8,
    response: foundation.json.Raw,
    kept: []const u8,
    from: []const u8,
};

/// A model request's answer that came to nothing — one that failed, a recap that gave none, or one its turn stopped
/// before it was used — its response as it came: what the provider said, what it took, kept for the record, as every
/// answer of a model request is, and never sent to the model.
pub const Failure = struct {
    id: []const u8,
    type: enum { failure } = .failure,
    request: []const u8,
    response: foundation.json.Raw,
};

/// How the model is asked from here on, where the person changed it before a request: how hard it reasons. One before
/// a window's first reply is how the window is asked; one after it, a change where it stands, so what the window began
/// with holds.
pub const Configuration = struct {
    id: []const u8,
    type: enum { configuration } = .configuration,
    effort: vocabulary.items.ReasoningEffort,
};

/// An input taken into the log: the operation that delivered it, whose it is, and the message as the model is sent it.
pub const Input = struct {
    id: []const u8,
    type: enum { input } = .input,
    delivery_id: []const u8,
    actor: []const u8,
    message: vocabulary.items.InputMessage,
    /// Who is told how the turn that takes it ends, where someone asked, as the input was delivered.
    reply_to: ?ReplyTo = null,
};

/// A fiber told how the turn that took an input ended, by mail of `key`: its process, and the commit that started it —
/// whichever is there, where it is none — as wait(2) takes a child's status.
pub const ReplyTo = struct { process: []const u8, started: ?u64 = null, key: []const u8 };

/// A model's reply, as it came — the vocabulary's response — to the model request of `request`, by its key, and
/// whether a stop cut it.
pub const Reply = struct {
    id: []const u8,
    type: enum { reply } = .reply,
    request: []const u8,
    response: foundation.json.Raw,
    cancelled: ?bool = null,
};

/// A turn's end, as the thread's fiber settles it: the turn, by its id — none for inputs that failed before a turn
/// ran — replied, failed or stopped, and why, unless replied.
pub const TurnEnd = struct {
    id: []const u8,
    type: enum { @"turn-end" } = .@"turn-end",
    turn: ?[]const u8 = null,
    outcome: Outcome,
    reason: ?[]const u8 = null,
};

pub const Outcome = enum { replied, failed, stopped };

/// Calls made under a call — by the program the call runs, as a script makes its tools' calls — as no reply holds
/// them: the call they were made under, by its id, and the calls, in the order they were made, as the vocabulary has a
/// model's, each by the id its result settles it by.
pub const Calls = struct {
    id: []const u8,
    type: enum { calls } = .calls,
    under: []const u8,
    calls: []const vocabulary.items.FunctionCall,
};

/// A call's result, as what made the call appends it once the call ended — its turn, for the model's: Siphon's id of
/// the call, the call it was made under where it was, how it ended, and its output, the vocabulary's. The model is sent
/// the results of its own calls alone, as a program reads its calls' results and tells the model what it makes of them.
pub const Result = struct {
    id: []const u8,
    type: enum { result } = .result,
    /// Siphon's id of the call, the key of the fiber that ran it; none for a call that never ran.
    call: ?[]const u8 = null,
    /// The call it was made under, by its id: a script's, the call of `execute` that ran the script; none for the
    /// model's own.
    under: ?[]const u8 = null,
    status: CallStatus,
    call_output: vocabulary.items.FunctionCallOutput,
};

/// How a call ended: run; its tool not among those the model may call; its arguments not fitting; its tool failing;
/// cut off; stopped.
pub const CallStatus = enum { ok, unavailable, @"invalid-arguments", @"tool-error", rejected, interrupted, stopped };

/// How a call ended, as its tool answers and its fiber ends with: its status, the output the model reads, and the files
/// it hands the model beside it — an image a read found.
pub const CallOutcome = struct { status: CallStatus, output: []const u8, files: []const OutputFile = &.{} };

/// A file a call's output hands the model beside its text, kept as the person's files are — by the reference its
/// content gives it, which the request is sent with the bytes of — and what it is.
pub const OutputFile = struct { ref: []const u8, media_type: []const u8 };

/// What every entry begins with, as a reader tells one from another: its id, its type, and the call it was made under,
/// for calls and results made under one.
pub const Head = struct { id: []const u8, type: []const u8, under: ?[]const u8 = null };

/// Where an entry is: its segment, and its line's offset and length there, its newline with it — so it is read again
/// as `pread` reads, in place.
pub const Address = struct { segment: []const u8, offset: u64, length: u64 };

/// A segment, by its name, and its length so far.
pub const Segment = struct { name: []const u8, length: u64 };

/// The log's directory in the thread at `thread`.
pub fn pathOf(arena: Allocator, thread: []const u8) Allocator.Error![]const u8 {
    return beak.join(arena, thread, "log");
}

/// The segments of the log of the thread at `thread`, in the order they began.
pub fn segments(volume: beak.Volume, arena: *const Allocator, thread: []const u8) ![]const Segment {
    const found = try volume.list(arena, try pathOf(arena.*, thread), "");
    const out = try arena.alloc(Segment, found.len);
    for (found, out) |entry, *segment| segment.* = .{ .name = try arena.dupe(u8, beak.slice(entry.name)), .length = entry.length };
    return out;
}

/// What appends a phase's entries to the log of a thread, with the phase's commit: the segment they go to, as the last
/// commit left it and with what the phase appended since.
pub const Writer = struct {
    phase: *Phase,
    thread: []const u8,
    last: ?Segment,

    /// A writer of the phase's entries to the log of the thread at `thread`.
    pub fn init(phase: *Phase, thread: []const u8) !Writer {
        return .{ .phase = phase, .thread = thread, .last = try lastSegment(phase.runtime.volume, &phase.arena, thread) };
    }

    /// Appends `entry`, as one line: to the last segment, or to one it begins where there is none or the last would
    /// pass its bound, the last sealed. Where the entry is.
    pub fn append(writer: *Writer, entry: anytype) !Address {
        const phase = writer.phase;
        const line = try lineOf(phase.arena, entry);
        const fits = if (writer.last) |segment| segment.length + line.len <= segment_bytes_max else false;
        if (!fits) {
            if (writer.last) |segment| try phase.changes.seal(try segmentPath(phase.arena, writer.thread, segment.name));
            writer.last = .{ .name = try std.mem.concat(phase.arena, u8, &.{ entry.id, segment_extension }), .length = 0 };
        }
        const segment = &writer.last.?;
        try phase.changes.append(try segmentPath(phase.arena, writer.thread, segment.name), line);
        defer segment.length += line.len;
        return .{ .segment = segment.name, .offset = segment.length, .length = line.len };
    }

    /// Appends the result of the call `call_id`, made under the call `under` where it was, by the fiber keyed `key`
    /// where one ran it, as `outcome` says: an output marked an error wherever the call did not run to what it was
    /// asked, as a provider tells its model.
    pub fn appendResult(writer: *Writer, key: ?[]const u8, under: ?[]const u8, call_id: []const u8, outcome: CallOutcome) !void {
        _ = try writer.append(Result{
            .id = try writer.phase.mint(),
            .call = key,
            .under = under,
            .status = outcome.status,
            .call_output = .{
                .call_id = call_id,
                .output = if (outcome.files.len == 0) .{ .text = outcome.output } else .{ .parts = try partsOf(writer.phase.arena, outcome) },
                .octoii = if (outcome.status == .ok) null else .{ .is_error = true },
            },
        });
    }
};

/// The output of `outcome` as parts: its text, then each file it hands the model, an image by its reference.
fn partsOf(arena: Allocator, outcome: CallOutcome) Allocator.Error![]const vocabulary.content.InputContent {
    const parts = try arena.alloc(vocabulary.content.InputContent, outcome.files.len + 1);
    parts[0] = .{ .input_text = .{ .text = outcome.output } };
    for (outcome.files, parts[1..]) |file, *part| {
        part.* = .{ .input_image = .{ .detail = .auto, .octoii = .{ .ref = file.ref, .media_type = file.media_type } } };
    }
    return parts;
}

/// The calls of functions the reply entry `line` made, in the order its model made them.
pub fn callsOf(arena: Allocator, line: []const u8) ![]const vocabulary.items.FunctionCall {
    const reply = try foundation.json.decode(Reply, arena, line);
    const response = try foundation.json.decode(vocabulary.Response, arena, reply.response.text);
    var out: std.ArrayList(vocabulary.items.FunctionCall) = .empty;
    for (response.output) |item| switch (item) {
        .function_call => |call| try out.append(arena, call),
        else => {},
    };
    return out.items;
}

/// `entry` as a line of the log: its canonical JSON, then a newline.
pub fn lineOf(arena: Allocator, entry: anytype) Allocator.Error![]const u8 {
    return std.mem.concat(arena, u8, &.{ try foundation.json.encode(arena, entry), "\n" });
}

/// The path of the segment `name` of the log of the thread at `thread`.
pub fn segmentPath(arena: Allocator, thread: []const u8, name: []const u8) Allocator.Error![]const u8 {
    return beak.join(arena, try pathOf(arena, thread), name);
}

/// Every line of the log of the thread at `thread`, in order, each without its newline.
pub fn lines(volume: beak.Volume, arena: *const Allocator, thread: []const u8) ![]const []const u8 {
    return (try readFrom(volume, arena, thread, null, std.math.maxInt(u64))).lines;
}

/// The line of the entry at `address` in the log of the thread at `thread`, without its newline.
pub fn lineAt(volume: beak.Volume, arena: *const Allocator, thread: []const u8, address: Address) ![]const u8 {
    const line = try volume.read(arena, try segmentPath(arena.*, thread, address.segment), address.offset, address.length);
    if (line.len != address.length or !std.mem.endsWith(u8, line, "\n")) return error.NoSuchEntry;
    return line[0 .. line.len - 1];
}

/// Where a reader of a log stands: the segment it read, and how far.
pub const Cursor = struct { segment: []const u8, offset: u64 };

/// What a reader found: the lines after where it stood, each without its newline; where it stands after them, null for
/// a log not begun; and whether lines are left past it.
pub const Read = struct { lines: []const []const u8, cursor: ?Cursor, more: bool };

/// The lines of the log of the thread at `thread` past `from` — from the log's first, where it is null — as the last
/// commit left it: about `bytes_max` of them, though a whole line at least where one is left, the rest of its segment
/// and then each one after. A reader that goes on from where it stands reads each line once.
pub fn readFrom(volume: beak.Volume, arena: *const Allocator, thread: []const u8, from: ?Cursor, bytes_max: u64) !Read {
    var at = from orelse begun: {
        const first = try segmentAt(volume, arena, thread, .{ .limit = 1 }) orelse return .{ .lines = &.{}, .cursor = null, .more = false };
        break :begun Cursor{ .segment = first.name, .offset = 0 };
    };
    var out: std.ArrayList([]const u8) = .empty;
    var left = bytes_max;
    while (true) {
        const path = try segmentPath(arena.*, thread, at.segment);
        const size = (try volume.stat(arena, path) orelse return error.NoSuchSegment).length;
        if (at.offset > size) return error.InvalidCursor;
        if (at.offset < size) {
            if (left == 0) return .{ .lines = out.items, .cursor = at, .more = true };
            const read = try linesAt(volume, arena, path, at.offset, size, left);
            try out.appendSlice(arena.*, read.lines);
            at.offset += read.bytes;
            left -|= read.bytes;
            if (at.offset < size) return .{ .lines = out.items, .cursor = at, .more = true };
        }
        const next = try segmentAt(volume, arena, thread, .{ .after = at.segment, .limit = 1 }) orelse return .{ .lines = out.items, .cursor = at, .more = false };
        at = .{ .segment = next.name, .offset = 0 };
    }
}

/// What a reader found reading back: the lines before where it stood, in the log's order, each without its newline;
/// where the log ended as it was read, for one who reads on from there, null for a log not begun; and whether the lines
/// reach the log's start.
pub const Page = struct { lines: []const []const u8, end: ?Cursor, complete: bool };

/// How much of a segment a reader reading back reads at a time.
const back_bytes = 64 << 10;

/// The last lines of the log of the thread at `thread` before the entry of id `before` — before the log's end, where it is
/// null — at most `count`, in the log's order, as the last commit left it: read back a block at a time, as a history is
/// read back a page at a time. An entry is found by its id, in the last segment named at most it, as ids rise along the
/// log.
pub fn readBefore(volume: beak.Volume, arena: *const Allocator, thread: []const u8, before: ?[]const u8, count: usize) !Page {
    const all = try segments(volume, arena, thread);
    if (all.len == 0) return .{ .lines = &.{}, .end = null, .complete = true };
    const last = all[all.len - 1];
    var index = all.len - 1;
    var offset = last.length;
    if (before) |id| {
        while (index > 0 and std.mem.order(u8, beginsWith(all[index].name), id) == .gt) index -= 1;
        offset = try lineStart(volume, arena, try segmentPath(arena.*, thread, all[index].name), all[index].length, id) orelse return error.NoSuchEntry;
    }
    var newest_first: std.ArrayList([]const u8) = .empty;
    while (true) {
        const reached = try readBack(volume, arena, try segmentPath(arena.*, thread, all[index].name), offset, count - newest_first.items.len, &newest_first);
        const complete = reached and index == 0;
        if (newest_first.items.len == count or complete) {
            std.mem.reverse([]const u8, newest_first.items);
            return .{ .lines = newest_first.items, .end = .{ .segment = last.name, .offset = last.length }, .complete = complete };
        }
        index -= 1;
        offset = all[index].length;
    }
}

/// Where the entry of id `id` begins in the log of the thread at `thread`: in the last segment named at most it, as ids
/// rise along the log; null where the log holds no such entry.
pub fn cursorOf(volume: beak.Volume, arena: *const Allocator, thread: []const u8, id: []const u8) !?Cursor {
    const all = try segments(volume, arena, thread);
    var index = all.len;
    while (index > 0) : (index -= 1) {
        const segment = all[index - 1];
        if (std.mem.order(u8, beginsWith(segment.name), id) == .gt) continue;
        const offset = try lineStart(volume, arena, try segmentPath(arena.*, thread, segment.name), segment.length, id) orelse return null;
        return .{ .segment = segment.name, .offset = offset };
    }
    return null;
}

/// The id of the entry that begins the segment of `name`.
fn beginsWith(name: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, name, segment_extension)) name[0 .. name.len - segment_extension.len] else name;
}

/// Where the line of the entry `id` starts in the segment at `path`, `length` long; null where it holds no such entry.
fn lineStart(volume: beak.Volume, arena: *const Allocator, path: []const u8, length: u64, id: []const u8) !?u64 {
    const head = try std.mem.concat(arena.*, u8, &.{ "{\"id\":", try foundation.json.encode(arena.*, id), "," });
    var offset: u64 = 0;
    while (offset < length) {
        const read = try linesAt(volume, arena, path, offset, length, back_bytes);
        var at = offset;
        for (read.lines) |line| {
            if (std.mem.startsWith(u8, line, head)) return at;
            at += line.len + 1;
        }
        offset += read.bytes;
    }
    return null;
}

/// Appends to `out`, newest first, at most `want` whole lines of the segment at `path` that end at or before `offset` — a
/// line's start, or the segment's end — read back a block at a time; whether it read back to the segment's start.
fn readBack(volume: beak.Volume, arena: *const Allocator, path: []const u8, offset: u64, want: usize, out: *std.ArrayList([]const u8)) !bool {
    var from = offset;
    // The segment's bytes from `from` to the start of the earliest line taken: whole lines, each ending in its newline.
    var held: []const u8 = "";
    var taken: usize = 0;
    while (taken < want) {
        if (held.len > 0) {
            if (std.mem.lastIndexOfScalar(u8, held[0 .. held.len - 1], '\n')) |newline| {
                try out.append(arena.*, held[newline + 1 .. held.len - 1]);
                held = held[0 .. newline + 1];
                taken += 1;
                continue;
            }
            if (from == 0) {
                try out.append(arena.*, held[0 .. held.len - 1]);
                held = "";
                taken += 1;
                continue;
            }
        } else if (from == 0) break;
        const start = from -| back_bytes;
        held = try std.mem.concat(arena.*, u8, &.{ try volume.read(arena, path, start, from - start), held });
        from = start;
    }
    return from == 0 and held.len == 0;
}

/// Whether a reader of the log of the thread at `thread` can stand at `cursor`: in a segment the log holds, at its
/// start, at its end, or where a line starts.
pub fn holds(volume: beak.Volume, arena: *const Allocator, thread: []const u8, cursor: Cursor) !bool {
    if (cursor.segment.len == 0 or std.mem.indexOfScalar(u8, cursor.segment, '/') != null) return false;
    const path = try segmentPath(arena.*, thread, cursor.segment);
    const segment = try volume.stat(arena, path) orelse return false;
    if (segment.directory != null or cursor.offset > segment.length) return false;
    if (cursor.offset == 0) return true;
    return std.mem.eql(u8, try volume.read(arena, path, cursor.offset - 1, 1), "\n");
}

/// The whole lines of the file at `path` from `offset`, short of `end`: about `bytes_max` of them, though one at least,
/// each without its newline; and the bytes they took, with their newlines.
fn linesAt(volume: beak.Volume, arena: *const Allocator, path: []const u8, offset: u64, end: u64, bytes_max: u64) !struct { lines: []const []const u8, bytes: u64 } {
    var length = @min(bytes_max, end - offset);
    while (true) {
        const bytes = try volume.read(arena, path, offset, length);
        if (std.mem.lastIndexOfScalar(u8, bytes, '\n')) |last| {
            var out: std.ArrayList([]const u8) = .empty;
            var split = std.mem.splitScalar(u8, bytes[0..last], '\n');
            while (split.next()) |line| if (line.len > 0) try out.append(arena.*, line);
            return .{ .lines = out.items, .bytes = last + 1 };
        }
        // A line longer than the bound is read whole; a segment ends with a whole line, as each is appended whole.
        if (offset + length >= end) return error.DamagedLog;
        length = @min(length * 2, end - offset);
    }
}

/// The segment of the log of the thread at `thread` that `range` picks first; null where it picks none.
fn segmentAt(volume: beak.Volume, arena: *const Allocator, thread: []const u8, range: beak.Range) !?Segment {
    const found = try volume.page(arena, try pathOf(arena.*, thread), range);
    if (found.len == 0) return null;
    return .{ .name = try arena.dupe(u8, beak.slice(found[0].name)), .length = found[0].length };
}

/// The last segment of the log of the thread at `thread`, the one appended to; null for a log not begun.
pub fn lastSegment(volume: beak.Volume, arena: *const Allocator, thread: []const u8) !?Segment {
    return segmentAt(volume, arena, thread, .{ .reverse = true, .limit = 1 });
}

/// The id and type of the entry `line` holds.
pub fn headOf(arena: Allocator, line: []const u8) !Head {
    return foundation.json.decode(Head, arena, line);
}

test "an entry is one line of canonical JSON: its id and type first, its fields in whole words" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const end: TurnEnd = .{ .id = "019a", .outcome = .failed, .reason = "the model failed" };
    try std.testing.expectEqualStrings("{\"id\":\"019a\",\"type\":\"turn-end\",\"outcome\":\"failed\",\"reason\":\"the model failed\"}\n", try lineOf(arena, end));
    const head = try headOf(arena, "{\"id\":\"019b\",\"type\":\"reply\",\"response\":{}}");
    try std.testing.expectEqualStrings("019b", head.id);
    try std.testing.expectEqualStrings("reply", head.type);
}
