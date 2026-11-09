//! Multipart form data: the fields of a form, files among them, written as one body under a boundary, and read back
//! from such a body.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// A field of a form: text, or a file with its name and type.
pub const Field = struct {
    name: []const u8,
    /// A text field's value.
    value: ?[]const u8 = null,
    /// A file's name, type and bytes.
    filename: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    data: ?[]const u8 = null,
};

/// A form written: its body, and the `Content-Type` that names its boundary.
pub const Body = struct { content_type: []const u8, bytes: []const u8 };

/// `fields` as one body under `boundary`, which none of them may hold.
pub fn encode(arena: Allocator, boundary: []const u8, fields: []const Field) Allocator.Error!Body {
    var out: std.ArrayList(u8) = .empty;
    for (fields) |field| {
        try out.print(arena, "--{s}\r\nContent-Disposition: form-data; name=\"{s}\"", .{ boundary, field.name });
        if (field.filename) |filename| try out.print(arena, "; filename=\"{s}\"", .{filename});
        try out.appendSlice(arena, "\r\n");
        if (field.content_type) |content_type| try out.print(arena, "Content-Type: {s}\r\n", .{content_type});
        try out.appendSlice(arena, "\r\n");
        try out.appendSlice(arena, field.data orelse field.value orelse "");
        try out.appendSlice(arena, "\r\n");
    }
    try out.print(arena, "--{s}--\r\n", .{boundary});
    return .{ .content_type = try arena.print("multipart/form-data; boundary={s}", .{boundary}), .bytes = out.items };
}

/// The fields of `body`, a form whose `Content-Type` is `content_type`; null where it is no form.
pub fn parse(arena: Allocator, content_type: []const u8, body: []const u8) Allocator.Error!?[]const Field {
    const at = std.mem.indexOf(u8, content_type, "boundary=") orelse return null;
    const boundary = std.mem.trim(u8, content_type[at + "boundary=".len ..], "\" ");
    const delimiter = try arena.print("--{s}", .{boundary});
    var fields: std.ArrayList(Field) = .empty;
    var parts = std.mem.splitSequence(u8, body, delimiter);
    _ = parts.next();
    while (parts.next()) |part| {
        if (std.mem.startsWith(u8, part, "--")) break;
        const trimmed = if (std.mem.startsWith(u8, part, "\r\n")) part[2..] else part;
        const split = std.mem.indexOf(u8, trimmed, "\r\n\r\n") orelse return null;
        var content = trimmed[split + 4 ..];
        if (std.mem.endsWith(u8, content, "\r\n")) content = content[0 .. content.len - 2];
        var field: Field = .{ .name = "" };
        var lines = std.mem.splitSequence(u8, trimmed[0..split], "\r\n");
        while (lines.next()) |line| {
            if (std.ascii.startsWithIgnoreCase(line, "content-type:")) field.content_type = std.mem.trim(u8, line["content-type:".len..], " ");
            if (!std.ascii.startsWithIgnoreCase(line, "content-disposition:")) continue;
            field.name = quoted(line, "name=\"") orelse return null;
            field.filename = quoted(line, "filename=\"");
        }
        // A file has its name; a field without one is text, whatever type it names.
        if (field.filename != null) field.data = content else field.value = content;
        try fields.append(arena, field);
    }
    return fields.items;
}

/// The quoted value after `key` in `line`, such as a disposition's name.
fn quoted(line: []const u8, comptime key: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, key)) |at| {
        // `filename="` holds `name="`: a name is the one not part of another key.
        if (at > 0 and std.ascii.isAlphabetic(line[at - 1])) {
            from = at + key.len;
            continue;
        }
        const start = at + key.len;
        const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse return null;
        return line[start..end];
    }
    return null;
}

test "a form is read back as it was written" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const written = try encode(arena, "xyz", &.{ .{ .name = "model", .value = "whisper-1" }, .{ .name = "file", .filename = "audio.mp3", .content_type = "audio/mpeg", .data = "ID3\r\nraw" } });
    try std.testing.expectEqualStrings("multipart/form-data; boundary=xyz", written.content_type);
    const read = (try parse(arena, written.content_type, written.bytes)).?;
    try std.testing.expectEqual(@as(usize, 2), read.len);
    try std.testing.expectEqualStrings("whisper-1", read[0].value.?);
    try std.testing.expectEqualStrings("audio.mp3", read[1].filename.?);
    try std.testing.expectEqualStrings("audio/mpeg", read[1].content_type.?);
    try std.testing.expectEqualStrings("ID3\r\nraw", read[1].data.?);
}
