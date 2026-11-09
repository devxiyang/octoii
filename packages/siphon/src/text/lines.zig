//! A text's lines as a page shows them, gathered from its bytes a range at a time as they are read, till the page is
//! whole and the line after it seen: each line its number, from 1, its text without its ending, a byte that begins no
//! UTF-8 character shown as U+FFFD, cut past as many characters as a line shows; a NUL among the bytes telling that
//! they are no text.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// A line as shown: its number, from 1; its text; and whether it was cut.
pub const Line = struct { number: usize, text: []const u8, cut: bool };

/// What a page holds: from which line, from 1; how many lines at most; how many bytes they take at most, each as
/// `N: text` and a newline; and how many characters of a line it shows, past which the line is cut.
pub const Bounds = struct { offset: usize = 1, limit: usize = 2000, bytes_max: usize = 48 * 1024, line_chars_max: usize = 2000 };

/// A page of a text's lines, taken a range of its bytes at a time: the lines in `arena`, the ranges the caller's to let
/// go of once taken.
pub const Pager = struct {
    arena: Allocator,
    bounds: Bounds,
    lines: std.ArrayList(Line) = .empty,
    /// The bytes the page's lines take.
    bytes: usize = 0,
    /// The lines seen.
    seen: usize = 0,
    /// Whether a line past the page was seen.
    more: bool = false,
    /// Whether a NUL was among the bytes: no text.
    binary: bool = false,
    /// The line being gathered, kept to as many bytes as can show its characters, and more, to tell it was cut.
    gathering: std.ArrayList(u8) = .empty,
    /// Whether a line is begun past the last newline taken.
    begun: bool = false,

    /// Takes the next range of the text; whether the page wants more.
    pub fn take(pager: *Pager, range: []const u8) error{OutOfMemory}!bool {
        if (std.mem.indexOfScalar(u8, range, 0) != null) {
            pager.binary = true;
            return false;
        }
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, range, start, '\n')) |newline| {
            try pager.gather(range[start..newline]);
            if (!try pager.end()) return false;
            start = newline + 1;
        }
        if (start < range.len) {
            try pager.gather(range[start..]);
            pager.begun = true;
        }
        return true;
    }

    /// Takes the end of the text: the line begun past its last newline, where one is.
    pub fn finish(pager: *Pager) error{OutOfMemory}!void {
        if (pager.begun) _ = try pager.end();
    }

    /// Whether the page reached the text's end: no line past it seen.
    pub fn whole(pager: *const Pager) bool {
        return !pager.more;
    }

    fn gather(pager: *Pager, piece: []const u8) error{OutOfMemory}!void {
        const kept_max = pager.bounds.line_chars_max * 4 + 8;
        const room = kept_max -| pager.gathering.items.len;
        try pager.gathering.appendSlice(pager.arena, piece[0..@min(piece.len, room)]);
    }

    /// Ends the line gathered: kept where the page has room for it; false once it is past the page.
    fn end(pager: *Pager) error{OutOfMemory}!bool {
        defer {
            pager.gathering = .empty;
            pager.begun = false;
        }
        pager.seen += 1;
        if (pager.seen < pager.bounds.offset) return true;
        const shown = try shownLine(pager.arena, pager.gathering.items, pager.bounds.line_chars_max);
        const bytes = digitsOf(pager.seen) + 2 + shown.text.len + 1;
        if (pager.lines.items.len >= pager.bounds.limit or pager.bytes + bytes > pager.bounds.bytes_max) {
            pager.more = true;
            return false;
        }
        try pager.lines.append(pager.arena, .{ .number = pager.seen, .text = shown.text, .cut = shown.cut });
        pager.bytes += bytes;
        return true;
    }
};

/// A line as shown: its `\r` left out, each byte that begins no UTF-8 character as U+FFFD, cut past `chars_max`
/// characters.
fn shownLine(arena: Allocator, raw: []const u8, chars_max: usize) error{OutOfMemory}!struct { text: []const u8, cut: bool } {
    const line = if (std.mem.endsWith(u8, raw, "\r")) raw[0 .. raw.len - 1] else raw;
    var text: std.ArrayList(u8) = .empty;
    var chars: usize = 0;
    var at: usize = 0;
    while (at < line.len) : (chars += 1) {
        if (chars == chars_max) return .{ .text = text.items, .cut = true };
        const length = std.unicode.utf8ByteSequenceLength(line[at]) catch 0;
        const whole = length > 0 and at + length <= line.len and decodes(line[at..][0..length]);
        if (whole) {
            try text.appendSlice(arena, line[at..][0..length]);
            at += length;
        } else {
            try text.appendSlice(arena, "\u{fffd}");
            at += 1;
        }
    }
    return .{ .text = text.items, .cut = false };
}

/// Whether `bytes` are one UTF-8 character.
fn decodes(bytes: []const u8) bool {
    _ = std.unicode.utf8Decode(bytes) catch return false;
    return true;
}

fn digitsOf(number: usize) usize {
    var count: usize = 1;
    var rest = number / 10;
    while (rest > 0) : (rest /= 10) count += 1;
    return count;
}

/// The page `bounds` take of `text`, given in ranges of `range` bytes, for the tests.
fn paged(arena: Allocator, text: []const u8, range: usize, bounds: Bounds) !Pager {
    var pager: Pager = .{ .arena = arena, .bounds = bounds };
    var at: usize = 0;
    while (at < text.len) : (at += range) {
        if (!try pager.take(text[at..@min(text.len, at + range)])) return pager;
    }
    try pager.finish();
    return pager;
}

test "a page gathers a text's lines across its ranges: shown as UTF-8, cut where long, and whether more follow" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const text = "one\r\ntwo\n\xffbad\nabcdefghij\nfive";
    for ([_]usize{ 1, 3, 64 }) |range| {
        const whole = try paged(arena, text, range, .{ .line_chars_max = 5 });
        try std.testing.expect(whole.whole());
        try std.testing.expectEqual(@as(usize, 5), whole.lines.items.len);
        try std.testing.expectEqualStrings("one", whole.lines.items[0].text);
        try std.testing.expectEqualStrings("\u{fffd}bad", whole.lines.items[2].text);
        try std.testing.expectEqualStrings("abcde", whole.lines.items[3].text);
        try std.testing.expect(whole.lines.items[3].cut);
        try std.testing.expectEqualStrings("five", whole.lines.items[4].text);
    }
    const page = try paged(arena, text, 4, .{ .offset = 2, .limit = 2 });
    try std.testing.expectEqual(@as(usize, 2), page.lines.items[0].number);
    try std.testing.expectEqual(@as(usize, 2), page.lines.items.len);
    try std.testing.expect(!page.whole());
    // A text ending with a newline has no line after it; a NUL tells it is no text.
    try std.testing.expectEqual(@as(usize, 2), (try paged(arena, "a\nb\n", 2, .{})).seen);
    try std.testing.expect((try paged(arena, "text\x00more", 64, .{})).binary);
    // A page holds no more bytes than it may, the line past them left to the next.
    const bounded = try paged(arena, "0123456789\n0123456789\n", 64, .{ .bytes_max = 20 });
    try std.testing.expectEqual(@as(usize, 1), bounded.lines.items.len);
    try std.testing.expect(!bounded.whole());
}
