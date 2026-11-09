//! An edit of a text: `old` found in it and replaced with `new`, once or at every match. `old` is found on the text
//! read with each `\r\n` as `\n`, by the first of three tiers that finds it — exactly; with typographic characters read
//! as their plain ones; line by line, trailing spaces and tabs left aside — and each match is replaced by `new`'s
//! lines, each ending as the line it stands for did, a line the edit keeps written as the file wrote it. Where `old` and
//! `new` differ in their `\r` alone, the edit is of line endings: matched and replaced as written. An edit that cannot be
//! made as asked is refused, with why.
const std = @import("std");
const Allocator = std.mem.Allocator;
const diff = @import("diff.zig");

pub const Tier = enum { exact, typographic, lines };

/// An edit asked for: what to find, what to put in its place, and whether at every match.
pub const Request = struct { old: []const u8, new: []const u8, all: bool = false };

/// Why an edit is refused: `old` empty, or the same as `new`; no match; more than one, not asked to replace every one;
/// or a text the edit leaves as it was.
pub const Refusal = union(enum) {
    empty,
    same,
    not_found,
    many: usize,
    unchanged,

    /// The reason as a failure tells it.
    pub fn reasonOf(refusal: Refusal) []const u8 {
        return switch (refusal) {
            .empty => "empty",
            .same => "same",
            .not_found => "not-found",
            .many => "many",
            .unchanged => "unchanged",
        };
    }
};

/// What an edit made of a text: the text after, how many matches it replaced and by which tier it found them; or why
/// it is refused.
pub const Edited = union(enum) {
    made: struct { text: []const u8, replacements: usize, tier: Tier },
    refused: Refusal,
};

/// A place in a text: from its start to its end.
const Span = struct { start: usize, end: usize };

/// `text` edited as `request` asks, in `arena`.
pub fn edited(arena: Allocator, text: []const u8, request: Request) error{OutOfMemory}!Edited {
    if (request.old.len == 0) return .{ .refused = .empty };
    if (std.mem.eql(u8, request.old, request.new)) return .{ .refused = .same };
    if (std.mem.eql(u8, try withoutCr(arena, request.old), try withoutCr(arena, request.new))) {
        const spans = try occurrences(arena, text, request.old);
        if (refusalOf(spans.len, request.all)) |why| return .{ .refused = why };
        return madeOf(text, try replacedAsWritten(arena, text, spans, request.new), spans.len, .exact);
    }
    const old = (try lfView(arena, request.old)).text;
    const view = try lfView(arena, text);
    const found = try matched(arena, view.text, old);
    if (refusalOf(found.spans.len, request.all)) |why| return .{ .refused = why };
    const after = try replaced(arena, text, view, found.spans, old, (try lfView(arena, request.new)).text);
    return madeOf(text, after, found.spans.len, found.tier);
}

fn refusalOf(matches: usize, all: bool) ?Refusal {
    if (matches == 0) return .not_found;
    if (matches > 1 and !all) return .{ .many = matches };
    return null;
}

fn madeOf(before: []const u8, after: []const u8, replacements: usize, tier: Tier) Edited {
    if (std.mem.eql(u8, before, after)) return .{ .refused = .unchanged };
    return .{ .made = .{ .text = after, .replacements = replacements, .tier = tier } };
}

/// Where `old` matches `view`, by the first tier that finds it.
fn matched(arena: Allocator, view: []const u8, old: []const u8) error{OutOfMemory}!struct { spans: []const Span, tier: Tier } {
    const exact = try occurrences(arena, view, old);
    if (exact.len > 0) return .{ .spans = exact, .tier = .exact };
    const plain_view = try plainView(arena, view);
    const plain = try occurrences(arena, plain_view.text, (try plainView(arena, old)).text);
    if (plain.len > 0) {
        for (plain) |*span| span.* = .{ .start = plain_view.at[span.start], .end = plain_view.at[span.end] };
        return .{ .spans = plain, .tier = .typographic };
    }
    return .{ .spans = try lineSpans(arena, view, old), .tier = .lines };
}

/// Where `needle` occurs in `text`, left to right, none overlapping the one before.
fn occurrences(arena: Allocator, text: []const u8, needle: []const u8) error{OutOfMemory}![]Span {
    var out: std.ArrayList(Span) = .empty;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, needle)) |at| {
        try out.append(arena, .{ .start = at, .end = at + needle.len });
        from = at + needle.len;
    }
    return out.items;
}

fn withoutCr(arena: Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |byte| if (byte != '\r') try out.append(arena, byte);
    return out.items;
}

fn replacedAsWritten(arena: Allocator, text: []const u8, spans: []const Span, new: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    for (spans) |span| {
        try out.appendSlice(arena, text[at..span.start]);
        try out.appendSlice(arena, new);
        at = span.end;
    }
    try out.appendSlice(arena, text[at..]);
    return out.items;
}

/// A text read another way, and where each of its bytes, and its end, stands in the text it was read from.
const View = struct { text: []const u8, at: []const usize };

/// `text` read with each `\r\n` as `\n`, that `\n` standing where its `\r` does: a span that starts or ends there takes
/// or leaves the pair whole.
fn lfView(arena: Allocator, text: []const u8) error{OutOfMemory}!View {
    var read: std.ArrayList(u8) = .empty;
    var at: std.ArrayList(usize) = .empty;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        try at.append(arena, index);
        if (text[index] == '\r' and index + 1 < text.len and text[index + 1] == '\n') index += 1;
        try read.append(arena, text[index]);
    }
    try at.append(arena, text.len);
    return .{ .text = read.items, .at = at.items };
}

/// `text` read with each typographic character as its plain one: curly quotes as straight ones, Unicode dashes and the
/// minus sign as `-`, special spaces as a space.
fn plainView(arena: Allocator, text: []const u8) error{OutOfMemory}!View {
    var read: std.ArrayList(u8) = .empty;
    var at: std.ArrayList(usize) = .empty;
    var index: usize = 0;
    while (index < text.len) {
        try at.append(arena, index);
        if (typographicAt(text, index)) |found| {
            try read.append(arena, found.plain);
            index += found.length;
        } else {
            try read.append(arena, text[index]);
            index += 1;
        }
    }
    try at.append(arena, text.len);
    return .{ .text = read.items, .at = at.items };
}

/// The typographic character at `index` of `text`, its length and its plain one; none where another stands there.
fn typographicAt(text: []const u8, index: usize) ?struct { plain: u8, length: usize } {
    const length = std.unicode.utf8ByteSequenceLength(text[index]) catch return null;
    if (length < 2 or index + length > text.len) return null;
    const character = std.unicode.utf8Decode(text[index..][0..length]) catch return null;
    const plain: u8 = switch (character) {
        0x2018...0x201B => '\'',
        0x201C...0x201F => '"',
        0x2010...0x2015, 0x2212 => '-',
        0x00A0, 0x2000...0x200A, 0x202F, 0x205F, 0x3000 => ' ',
        else => return null,
    };
    return .{ .plain = plain, .length = length };
}

/// Whether two lines are the same as the line tier reads them: typographic characters as their plain ones, trailing
/// spaces and tabs left aside.
pub fn sameLoosely(a: []const u8, b: []const u8) bool {
    var left: Plain = .{ .text = a, .end = looseEndOf(a) };
    var right: Plain = .{ .text = b, .end = looseEndOf(b) };
    while (true) {
        const x = left.next();
        const y = right.next();
        if (x == null or y == null) return x == null and y == null;
        if (x.? != y.?) return false;
    }
}

/// A line's bytes as the line tier reads them, to an end.
const Plain = struct {
    text: []const u8,
    end: usize,
    at: usize = 0,

    fn next(plain: *Plain) ?u8 {
        if (plain.at >= plain.end) return null;
        if (typographicAt(plain.text, plain.at)) |found| {
            plain.at += found.length;
            return found.plain;
        }
        plain.at += 1;
        return plain.text[plain.at - 1];
    }
};

/// Where a line ends once its trailing spaces and tabs, typographic spaces among them, are left aside.
fn looseEndOf(line: []const u8) usize {
    var end = line.len;
    while (end > 0) {
        var start = end - 1;
        while (start > 0 and line[start] & 0xC0 == 0x80) start -= 1;
        const blank = switch (line[start]) {
            ' ', '\t' => true,
            else => if (typographicAt(line, start)) |found| found.plain == ' ' and start + found.length == end else false,
        };
        if (!blank) return end;
        end = start;
    }
    return 0;
}

/// A text split at `\n` into its lines, and whether it ends with one — the empty line after it left out.
const Split = struct { lines: []const []const u8, ends_with_newline: bool };

fn splitOf(arena: Allocator, text: []const u8) error{OutOfMemory}!Split {
    if (text.len == 0) return .{ .lines = &.{}, .ends_with_newline = false };
    var lines: std.ArrayList([]const u8) = .empty;
    var each = std.mem.splitScalar(u8, text, '\n');
    while (each.next()) |line| try lines.append(arena, line);
    const ends = lines.items[lines.items.len - 1].len == 0;
    if (ends) _ = lines.pop();
    return .{ .lines = lines.items, .ends_with_newline = ends };
}

/// The spans of whole lines of `view` that match `old`'s lines loosely, left to right, none overlapping the one before;
/// where `old` ends with a newline, a match takes the newline after its last line too.
fn lineSpans(arena: Allocator, view: []const u8, old: []const u8) error{OutOfMemory}![]const Span {
    const wanted = try splitOf(arena, old);
    var out: std.ArrayList(Span) = .empty;
    if (wanted.lines.len == 0) return out.items;
    var lines: std.ArrayList([]const u8) = .empty;
    var starts: std.ArrayList(usize) = .empty;
    var offset: usize = 0;
    var each = std.mem.splitScalar(u8, view, '\n');
    while (each.next()) |line| {
        try lines.append(arena, line);
        try starts.append(arena, offset);
        offset += line.len + 1;
    }
    // A match that takes the newline after its last line ends before the view's last line, which has none.
    const lines_matched = if (wanted.ends_with_newline) lines.items.len - 1 else lines.items.len;
    var at: usize = 0;
    while (at + wanted.lines.len <= lines_matched) {
        const all = for (wanted.lines, lines.items[at..][0..wanted.lines.len]) |line, found| {
            if (!sameLoosely(found, line)) break false;
        } else true;
        if (!all) {
            at += 1;
            continue;
        }
        const last = at + wanted.lines.len - 1;
        try out.append(arena, .{ .start = starts.items[at], .end = starts.items[last] + lines.items[last].len + @intFromBool(wanted.ends_with_newline) });
        at += wanted.lines.len;
    }
    return out.items;
}

pub const Ending = enum { none, lf, crlf };

/// A line as a text wrote it: its text and its own ending.
const Written = struct { text: []const u8, ending: Ending };

/// A text's lines with their own endings; a last line with none only where text follows the last newline.
fn writtenLinesOf(arena: Allocator, text: []const u8) error{OutOfMemory}![]const Written {
    var out: std.ArrayList(Written) = .empty;
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, start, '\n')) |at| {
        const crlf = at > start and text[at - 1] == '\r';
        try out.append(arena, .{ .text = text[start..if (crlf) at - 1 else at], .ending = if (crlf) .crlf else .lf });
        start = at + 1;
    }
    if (start < text.len) try out.append(arena, .{ .text = text[start..], .ending = .none });
    return out.items;
}

/// The ending more of `lines` have than the other; none where neither has one, or as many have each.
fn prevailingOf(lines: []const Written) ?Ending {
    var crlf: usize = 0;
    var lf: usize = 0;
    for (lines) |line| switch (line.ending) {
        .crlf => crlf += 1,
        .lf => lf += 1,
        .none => {},
    };
    if (crlf == lf) return null;
    return if (crlf > lf) .crlf else .lf;
}

/// A text's own ending: the one most of its lines have, else its first line's, else `\n`.
fn endingOfText(lines: []const Written) Ending {
    if (prevailingOf(lines)) |ending| return ending;
    for (lines) |line| if (line.ending != .none) return line.ending;
    return .lf;
}

fn textOfEnding(ending: Ending) []const u8 {
    return switch (ending) {
        .none => "",
        .lf => "\n",
        .crlf => "\r\n",
    };
}

/// `text` with the place each span of `view` stands for replaced by `new`'s lines, each ending as the place's lines do.
fn replaced(arena: Allocator, text: []const u8, view: View, spans: []const Span, old: []const u8, new: []const u8) error{OutOfMemory}![]const u8 {
    const ending = endingOfText(try writtenLinesOf(arena, text));
    const old_lines = (try splitOf(arena, old)).lines;
    const replacement = try splitOf(arena, new);
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    for (spans) |span| {
        const start = view.at[span.start];
        const end = view.at[span.end];
        try out.appendSlice(arena, text[at..start]);
        try writeReplacement(arena, &out, try writtenLinesOf(arena, text[start..end]), old_lines, replacement, ending);
        at = end;
    }
    try out.appendSlice(arena, text[at..]);
    return out.items;
}

/// Where a line of the replacement comes from: a line of `old` it keeps, one it changes in place, or none.
const Origin = union(enum) { kept: usize, changed: usize, added };

/// Writes the lines that replace a place, each with its ending from the place: a line kept keeps its own ending — and
/// the place's bytes where the replacement gives it as `old` did; a line changed in place takes the ending of the line
/// it stands for; a line added takes the ending most of the place's lines have, else the text's own.
fn writeReplacement(arena: Allocator, out: *std.ArrayList(u8), place: []const Written, old: []const []const u8, replacement: Split, text_ending: Ending) error{OutOfMemory}!void {
    const origins = try originsOf(arena, old, replacement.lines);
    const prevailing = prevailingOf(place) orelse text_ending;
    for (replacement.lines, origins, 0..) |line, origin, index| {
        const from: ?Written = switch (origin) {
            .added => null,
            .kept, .changed => |old_at| if (old_at < place.len) place[old_at] else null,
        };
        const as_written = origin == .kept and from != null and std.mem.eql(u8, old[origin.kept], line);
        try out.appendSlice(arena, if (as_written) from.?.text else line);
        if (index == replacement.lines.len - 1 and !replacement.ends_with_newline) continue;
        const own = if (from) |each| each.ending else .none;
        try out.appendSlice(arena, textOfEnding(if (own != .none) own else prevailing));
    }
}

/// Where each of `updated`'s lines comes from: the lines of `old` it keeps, read loosely, and in each change those it
/// puts in place of others, one for one.
fn originsOf(arena: Allocator, old: []const []const u8, updated: []const []const u8) error{OutOfMemory}![]const Origin {
    var out: std.ArrayList(Origin) = .empty;
    var old_at: usize = 0;
    var change_start: usize = 0;
    var removed: usize = 0;
    var added: usize = 0;
    for (try diff.runsOf(arena, old, updated, sameLoosely)) |run| switch (run.kind) {
        .equal => {
            for (0..added) |at| try out.append(arena, if (at < removed) .{ .changed = change_start + at } else .added);
            for (0..run.count) |at| try out.append(arena, .{ .kept = old_at + at });
            old_at += run.count;
            change_start = old_at;
            removed = 0;
            added = 0;
        },
        .delete => {
            removed += run.count;
            old_at += run.count;
        },
        .insert => added += run.count,
    };
    for (0..added) |at| try out.append(arena, if (at < removed) .{ .changed = change_start + at } else .added);
    return out.items;
}

test "an edit finds its text exactly, then typographically, then line by line, and keeps the file's line endings" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const exact = (try edited(arena, "let a = 1;\r\nlet b = 2;\r\n", .{ .old = "let b = 2;\n", .new = "let b = 3;\nlet c = 4;\n" })).made;
    try std.testing.expectEqual(Tier.exact, exact.tier);
    try std.testing.expectEqualStrings("let a = 1;\r\nlet b = 3;\r\nlet c = 4;\r\n", exact.text);
    const curly = (try edited(arena, "say \u{201c}hello\u{201d} \u{2014} now\n", .{ .old = "say \"hello\" - now", .new = "say \"bye\"" })).made;
    try std.testing.expectEqual(Tier.typographic, curly.tier);
    try std.testing.expectEqualStrings("say \"bye\"\n", curly.text);
    // Lines read loosely: a line the edit keeps is written as the file wrote it, its trailing spaces with it.
    const loose = (try edited(arena, "fn main() {   \n    run();\t\n}\n", .{ .old = "fn main() {\n    run();\n", .new = "fn main() {\n    go();\n" })).made;
    try std.testing.expectEqual(Tier.lines, loose.tier);
    try std.testing.expectEqualStrings("fn main() {   \n    go();\n}\n", loose.text);
    // A line added among CRLF lines ends as they do; the text's last line keeps having no newline.
    const added = (try edited(arena, "a\r\nb\r\nc", .{ .old = "b\nc", .new = "b\nx\nc" })).made;
    try std.testing.expectEqualStrings("a\r\nb\r\nx\r\nc", added.text);
}

test "an edit refuses what it cannot make, and replaces every match only where asked" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    try std.testing.expectEqual(Refusal.empty, (try edited(arena, "x", .{ .old = "", .new = "y" })).refused);
    try std.testing.expectEqual(Refusal.same, (try edited(arena, "x", .{ .old = "x", .new = "x" })).refused);
    try std.testing.expectEqual(Refusal.not_found, (try edited(arena, "x", .{ .old = "z", .new = "y" })).refused);
    try std.testing.expectEqual(@as(usize, 2), (try edited(arena, "a a", .{ .old = "a", .new = "b" })).refused.many);
    try std.testing.expectEqualStrings("b b", (try edited(arena, "a a", .{ .old = "a", .new = "b", .all = true })).made.text);
    // Where the two differ in their `\r` alone, the endings are what is edited: matched and replaced as written.
    try std.testing.expectEqualStrings("one\ntwo\n", (try edited(arena, "one\r\ntwo\n", .{ .old = "one\r\n", .new = "one\n" })).made.text);
    try std.testing.expectEqual(Refusal.unchanged, (try edited(arena, "a  \n", .{ .old = "a\n", .new = "a  \n" })).refused);
    try std.testing.expect(sameLoosely("say \u{201c}x\u{201d}\u{00a0}", "say \"x\"\t"));
    try std.testing.expect(!sameLoosely("a b", "ab"));
}
