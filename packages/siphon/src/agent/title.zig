//! A thread's title, as its model gives it: once its first turn begins with none, a fiber beside the thread's main
//! fiber asks the model, by a `model` request on the window its turn asks on — so what the window begins with is
//! shared with the turn's request, and its cache holds — for a few words of what the person asked, and gives the thread
//! that title where it still has none; a title the person gave first is kept. What the model answered is the fiber's
//! result, for the record; a request that failed leaves the thread untitled.
const std = @import("std");
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const beak = @import("../beak.zig");
const runtime_ = @import("../runtime.zig");
const Runtime = runtime_.Runtime;
const Phase = runtime_.Phase;
const Request = runtime_.Request;
const threads = @import("../threads.zig");
const log = threads.log;
const models = @import("models.zig");

/// The program of a thread's title fiber, and the fiber's key in the thread.
pub const program = "siphon.title";
const key = "title";

/// What a title request asks of the model, after the window.
pub const instruction = "Do not answer the person or do what they ask. Write a title for this thread instead: the topic of what they ask, in at most six words, in the language they wrote in, with no quotes and no full stop. Write the title alone.";

/// The most bytes a title is kept to.
const title_bytes_max = 80;

/// Registers the program of a thread's title fiber.
pub fn register(runtime: *Runtime) !void {
    try runtime.register(.{ .kind = program, .phase = titling });
}

/// Starts the title fiber of the thread at `thread`, from its main fiber's `phase`, where the thread has no title and
/// a model to ask, and the fiber was never started.
pub fn startFor(phase: *Phase, thread: []const u8) !void {
    const manifest = try threads.manifestOf(phase.runtime.volume, &phase.arena, thread);
    if (manifest.title != null or manifest.model == null) return;
    if (try phase.runtime.volume.stat(&phase.arena, try beak.childPath(phase.arena, thread, key)) != null) return;
    try phase.startIn(thread, key, program, null);
}

/// Where the fiber stands: its request of `key` asked.
const Asking = struct { key: []const u8 };

/// The fiber: asks the model for a title on the thread's first input; once it answers, gives the thread its words,
/// where it still has no title, and ends with the answer.
fn titling(_: ?*anyopaque, run: *Phase) anyerror!void {
    const thread = threads.threadOf(run.path);
    if (run.checkpoint.len == 0) return ask(run, thread);
    const asking = try foundation.json.decode(Asking, run.arena, run.checkpoint);
    const mail = try run.mailOf(asking.key) orelse return run.waitForMail(Phase.kept, asking.key);
    try run.take(asking.key);
    // Cut off as the volume opened again, it is asked once more; failed, the thread stays untitled.
    if (mail.interrupted()) return ask(run, thread);
    if (!std.mem.eql(u8, mail.name, Request.answered_name)) return run.done(null);
    const response = foundation.json.decode(vocabulary.Response, run.arena, mail.payload) catch return run.done(null);
    // The title is the thread's work, beside its main fiber rather than under it: what it used is charged there.
    try models.charge(&run.changes, try threads.mainOf(run.arena, thread), response);
    const words = (try models.textOf(run.arena, response)) orelse return run.done(response);
    // Words that hold no title leave the thread untitled, as a request that failed does.
    const title = titleOf(words);
    if (title.len == 0) return run.done(response);
    var manifest = try threads.manifestOf(run.runtime.volume, &run.arena, thread);
    if (manifest.title == null) {
        manifest.title = title;
        try run.changes.write(try beak.join(run.arena, thread, "thread.json"), try foundation.json.encode(run.arena, manifest));
    }
    return run.done(response);
}

/// Asks the thread's model for a title, on its window up to its first input, and sleeps till it answers; ends where
/// the thread has no input or no model.
fn ask(run: *Phase, thread: []const u8) !void {
    const first = try firstInput(run, thread) orelse return run.done(null);
    const manifest = try threads.manifestOf(run.runtime.volume, &run.arena, thread);
    const asked = try run.mint();
    try run.request(models.model_request, asked, models.ModelRequest{ .thread = threads.idOf(thread), .until = first, .model = manifest.model orelse return run.done(null), .instruction = instruction });
    return run.waitForMail(Asking{ .key = asked }, asked);
}

/// The id of the thread's first input; none where it has none: read from the log's start a block at a time, to it.
fn firstInput(run: *Phase, thread: []const u8) !?[]const u8 {
    var from: ?log.Cursor = null;
    while (true) {
        const read = try log.readFrom(run.runtime.volume, &run.arena, thread, from, 64 << 10);
        for (read.lines) |line| {
            const head = try log.headOf(run.arena, line);
            if (std.mem.eql(u8, head.type, "input")) return head.id;
        }
        if (!read.more) return null;
        from = read.cursor;
    }
}

/// The title the model's `words` give: their first line of words — a line of markup alone let go of, as a tag a model
/// echoes before its answer or a call it writes out in place of one — the quotes and the full stop around it let go
/// of, cut short at a character's end past `title_bytes_max`; empty where no line holds words.
pub fn titleOf(words: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, words, '\n');
    const line = while (lines.next()) |each| {
        const trimmed = std.mem.trim(u8, each, &std.ascii.whitespace);
        if (trimmed.len > 0 and !isMarkup(trimmed)) break trimmed;
    } else return "";
    var title = line;
    var trimmed = true;
    while (trimmed) {
        trimmed = false;
        for ([_][]const u8{ "\"", "'", "`", "*", "#", "“", "”", "「", "」", "。", ".", " " }) |mark| {
            if (std.mem.startsWith(u8, title, mark)) {
                title = title[mark.len..];
                trimmed = true;
            }
            if (std.mem.endsWith(u8, title, mark)) {
                title = title[0 .. title.len - mark.len];
                trimmed = true;
            }
        }
    }
    if (title.len <= title_bytes_max) return title;
    var end: usize = title_bytes_max;
    while (end > 0 and title[end] & 0xC0 == 0x80) end -= 1;
    return std.mem.trimEnd(u8, title[0..end], &std.ascii.whitespace);
}

/// Whether the trimmed, non-empty `line` is markup alone: a tag, or tags around what they hold, as `<effort>8</effort>`.
fn isMarkup(line: []const u8) bool {
    return line[0] == '<' and line[line.len - 1] == '>';
}

test "a title is the first line of what the model wrote, its quotes and full stop let go of, cut at a character's end" {
    try std.testing.expectEqualStrings("Fix the build", titleOf("\"Fix the build.\"\nmore"));
    try std.testing.expectEqualStrings("修复构建", titleOf("「修复构建」。"));
    try std.testing.expectEqualStrings("Plan the release", titleOf("  **Plan the release**  "));
    // A line of markup alone is no title: a tag echoed before the answer is passed over, and a call written out in
    // place of an answer holds none.
    try std.testing.expectEqualStrings("Fix the build", titleOf("<reasoning_effort>8</reasoning_effort>\n\nFix the build"));
    try std.testing.expectEqualStrings("", titleOf("<invoke name=\"read\">\n<parameter name=\"path\">a.ts</parameter>\n</invoke>"));
    try std.testing.expectEqualStrings("", titleOf("  \n"));
    const long = "一一一一一一一一一一一一一一一一一一一一一一一一一一一一一一一一一一一一一一一一";
    const cut = titleOf(long);
    try std.testing.expect(cut.len <= title_bytes_max);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
}
