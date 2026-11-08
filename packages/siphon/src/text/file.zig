//! A text file's bytes as text, and text as the bytes of a file: text is UTF-8 with no NUL, its byte-order mark apart
//! from it; new text that replaces a file's is written as the file held its own — its mark kept, and its lines ending
//! `\r\n` where the file's first line did.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const byte_order_mark = "\xef\xbb\xbf";

/// A file's text, and whether its bytes began with a byte-order mark.
pub const Text = struct { text: []const u8, marked: bool };

/// The text `bytes` hold; none where they hold a NUL or are no UTF-8.
pub fn textOf(bytes: []const u8) ?Text {
    const marked = std.mem.startsWith(u8, bytes, byte_order_mark);
    const text = if (marked) bytes[byte_order_mark.len..] else bytes;
    if (std.mem.indexOfScalar(u8, text, 0) != null or !std.unicode.utf8ValidateSlice(text)) return null;
    return .{ .text = text, .marked = marked };
}

/// The bytes `text` is written as, in a file that held `was`: its mark first where `was` had one.
pub fn bytesOf(arena: Allocator, text: []const u8, was: Text) error{OutOfMemory}![]const u8 {
    if (!was.marked) return text;
    return std.mem.concat(arena, u8, &.{ byte_order_mark, text });
}

/// `content` as it replaces a file that held `was`: its lines ending `\r\n` where `was`'s first line did.
pub fn replacing(arena: Allocator, content: []const u8, was: Text) error{OutOfMemory}![]const u8 {
    const newline = std.mem.indexOfScalar(u8, was.text, '\n') orelse return content;
    if (newline == 0 or was.text[newline - 1] != '\r') return content;
    var out: std.ArrayList(u8) = .empty;
    for (content, 0..) |byte, at| {
        if (byte == '\n' and (at == 0 or content[at - 1] != '\r')) try out.append(arena, '\r');
        try out.append(arena, byte);
    }
    return out.items;
}

test "a text file's bytes are text with its mark apart, and new text is written as the file held its own" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const marked = textOf("\xef\xbb\xbfone\r\ntwo\r\n").?;
    try std.testing.expect(marked.marked);
    try std.testing.expectEqualStrings("one\r\ntwo\r\n", marked.text);
    try std.testing.expect(textOf("a\x00b") == null);
    try std.testing.expect(textOf("\xff\xfe") == null);
    const written = try replacing(arena, "three\nfour\r\n", marked);
    try std.testing.expectEqualStrings("three\r\nfour\r\n", written);
    try std.testing.expectEqualStrings("\xef\xbb\xbfthree\r\nfour\r\n", try bytesOf(arena, written, marked));
    try std.testing.expectEqualStrings("a\nb", try replacing(arena, "a\nb", textOf("plain\n").?));
}
