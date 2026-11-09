//! The files of a machine as the tools and a person's view read and change them, through its namespace, by the
//! namespace's paths: a page of a text file, read a range at a time till the page is whole and the line after it seen;
//! a folder's entries, folders first; an image or a PDF as it is, what it is told by its first bytes, as file(1) tells
//! one; a name that is not there found as its canonical form, its spaces and apostrophes as a person types them, where
//! the system's name holds others; a file written, the folders on its way made, as it held its text; and an edit of a
//! text file. A failure of the namespace's is Beak's error, its reason left for `beak.told`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const beak = @import("../beak.zig");
const h = beak.h;
const text = @import("../text.zig");
const Machine = @import("../machine.zig");

/// How a read goes: the page of a text file's lines, or of a folder's entries, it gives; and how many bytes an image or
/// a PDF may take, read whole.
pub const ReadOptions = struct { bounds: text.Bounds = .{}, media_bytes_max: u64 = 32 << 20 };

/// What a read gives: a page of a text file, `line_count` where it reached the file's end; a page of a folder's
/// entries; an image or a PDF as it is; that a file is no text; that the page asked starts past the lines or entries
/// there are, how many there are; or that an image or a PDF is past the bytes a read takes. Each by the path read.
pub const Read = union(enum) {
    text: TextPage,
    directory: FolderPage,
    image: Media,
    pdf: Media,
    binary: struct { path: []const u8, size: u64 },
    past_end: struct { path: []const u8, count: usize },
    too_large: struct { path: []const u8, size: u64, limit: u64 },

    /// The path read: the one asked, or its canonical form's.
    pub fn pathOf(read_: Read) []const u8 {
        return switch (read_) {
            inline else => |each| each.path,
        };
    }
};

/// A page of a text file: its lines from the line `from`, and whether more follow — how many there are where none do.
pub const TextPage = struct { path: []const u8, size: u64, lines: []const text.Line, from: usize, more: bool, line_count: ?usize };

/// A page of a folder's entries: from the entry `from`, of `total`, and whether more follow.
pub const FolderPage = struct { path: []const u8, entries: []const h.beak_dirent, from: usize, total: usize, more: bool };

/// An image or a PDF as it is: its length in bytes, what it is, and its bytes.
pub const Media = struct { path: []const u8, size: u64, media_type: []const u8, bytes: []const u8 };

/// The bytes a read asks of the namespace at once.
const range_bytes = 256 * 1024;

/// The file or folder at `path` read as `options` say; error.NotFound where neither it nor its canonical form is there.
pub fn read(machine: Machine, arena: Allocator, path: []const u8, options: ReadOptions) beak.Error!Read {
    if (try statOf(machine, path)) |stat| return readFound(machine, arena, path, stat, options);
    const parent = parentOf(path);
    const wanted = try canonicalOf(arena, path[if (parent.len == 0) 0 else parent.len + 1..]);
    var found: ?[]const u8 = null;
    for (try listOf(machine, arena, parent)) |entry| {
        if (!std.mem.eql(u8, try canonicalOf(arena, beak.slice(entry.name)), wanted)) continue;
        if (found != null) return error.NotFound;
        found = beak.slice(entry.name);
    }
    const same = try joined(arena, parent, found orelse return error.NotFound);
    return readFound(machine, arena, same, try statOf(machine, same) orelse return error.NotFound, options);
}

fn readFound(machine: Machine, arena: Allocator, path: []const u8, stat: h.beak_stat, options: ReadOptions) beak.Error!Read {
    if (stat.type == h.BEAK_ENTRY_DIRECTORY) return readFolder(machine, arena, path, options.bounds);
    const first = try readRange(machine, arena, path, 0, range_bytes);
    if (mediaOf(first)) |media| {
        if (stat.size > options.media_bytes_max) return .{ .too_large = .{ .path = path, .size = stat.size, .limit = options.media_bytes_max } };
        const bytes = try readRange(machine, arena, path, 0, stat.size);
        const found: Media = .{ .path = path, .size = stat.size, .media_type = media, .bytes = bytes };
        return if (std.mem.eql(u8, media, "application/pdf")) .{ .pdf = found } else .{ .image = found };
    }
    return readText(machine, arena, path, stat.size, first, options.bounds);
}

/// A page of a text file, its ranges read into a scratch arena let go of as each is taken; its byte-order mark no
/// line's text, as an edit finds its text without it.
fn readText(machine: Machine, arena: Allocator, path: []const u8, size: u64, first: []const u8, bounds: text.Bounds) beak.Error!Read {
    var pager: text.Pager = .{ .arena = arena, .bounds = bounds };
    var scratch_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch_arena.deinit();
    const marked = std.mem.startsWith(u8, first, text.byte_order_mark);
    var range = if (marked) first[text.byte_order_mark.len..] else first;
    var position: u64 = if (marked) text.byte_order_mark.len else 0;
    while (true) {
        if (range.len == 0) {
            try pager.finish();
            break;
        }
        if (!try pager.take(range)) break;
        position += range.len;
        _ = scratch_arena.reset(.retain_capacity);
        range = try readRange(machine, scratch_arena.allocator(), path, position, range_bytes);
    }
    if (pager.binary) return .{ .binary = .{ .path = path, .size = size } };
    if (pager.lines.items.len == 0 and bounds.offset > 1 and pager.whole()) return .{ .past_end = .{ .path = path, .count = pager.seen } };
    return .{ .text = .{
        .path = path,
        .size = size,
        .lines = pager.lines.items,
        .from = bounds.offset,
        .more = !pager.whole(),
        .line_count = if (pager.whole()) pager.seen else null,
    } };
}

/// A page of a folder's entries, folders first, each in order by name; each entry takes its name's bytes and one more,
/// a folder's two, of the page's bytes.
fn readFolder(machine: Machine, arena: Allocator, path: []const u8, bounds: text.Bounds) beak.Error!Read {
    const entries = try listOf(machine, arena, path);
    std.mem.sort(h.beak_dirent, entries, {}, foldersFirst);
    if (bounds.offset > @max(1, entries.len)) return .{ .past_end = .{ .path = path, .count = entries.len } };
    const from = bounds.offset - 1;
    var kept: usize = 0;
    var bytes: usize = 0;
    for (entries[from..]) |entry| {
        const entry_bytes = entry.name.len + @intFromBool(entry.type == h.BEAK_ENTRY_DIRECTORY) + 1;
        if (kept >= bounds.limit or bytes + entry_bytes > bounds.bytes_max) break;
        kept += 1;
        bytes += entry_bytes;
    }
    return .{ .directory = .{ .path = path, .entries = entries[from .. from + kept], .from = bounds.offset, .total = entries.len, .more = from + kept < entries.len } };
}

fn foldersFirst(_: void, a: h.beak_dirent, b: h.beak_dirent) bool {
    const a_folder = a.type == h.BEAK_ENTRY_DIRECTORY;
    if (a_folder != (b.type == h.BEAK_ENTRY_DIRECTORY)) return a_folder;
    return std.mem.lessThan(u8, beak.slice(a.name), beak.slice(b.name));
}

/// What a file is, by its first bytes: a PNG, a JPEG, a GIF, a WebP or a PDF; none for any other.
fn mediaOf(bytes: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return "image/png";
    if (std.mem.startsWith(u8, bytes, "\xff\xd8\xff")) return "image/jpeg";
    if (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a")) return "image/gif";
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return "image/webp";
    if (std.mem.startsWith(u8, bytes, "%PDF-")) return "application/pdf";
    return null;
}

/// A name's canonical form: its special spaces as plain ones, its curly apostrophes as `'`.
fn canonicalOf(arena: Allocator, name: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var view = std.unicode.Utf8View.init(name) catch return name;
    var each = view.iterator();
    while (each.nextCodepointSlice()) |character| {
        const point = std.unicode.utf8Decode(character) catch 0;
        switch (point) {
            0x00a0, 0x2000...0x200a, 0x202f, 0x205f, 0x3000 => try out.append(arena, ' '),
            0x2018, 0x2019 => try out.append(arena, '\''),
            else => try out.appendSlice(arena, character),
        }
    }
    return out.items;
}

/// A change a write or an edit made to a text file: whether it made the file, the unified diff of it, named as the
/// caller shows the file, and how many lines it added and removed.
pub const Change = struct { created: bool, diff: []const u8, additions: usize, deletions: usize };

fn changeOf(arena: Allocator, before: ?[]const u8, after: []const u8, name: []const u8) error{OutOfMemory}!Change {
    const runs = try text.runsOf(arena, try text.linesOf(arena, before orelse ""), try text.linesOf(arena, after), text.exactly);
    const counts = text.countsOf(runs);
    return .{ .created = before == null, .diff = try text.unified(arena, before, after, name), .additions = counts.additions, .deletions = counts.deletions };
}

/// What a write did: the change it made, or that the path names a folder.
pub const Written = union(enum) { written: Change, directory };

/// Writes `content` as the file at `path`, the folders on its way made: a text file it replaces keeps its byte-order
/// mark, and `content`'s lines end `\r\n` where the file's first line did; a file that was no text is replaced as
/// given, as though it held nothing.
pub fn write(machine: Machine, arena: Allocator, path: []const u8, content: []const u8, name: []const u8) beak.Error!Written {
    switch (try textFileOf(machine, arena, path)) {
        .directory => return .directory,
        .missing => {
            const parent = parentOf(path);
            if (parent.len > 0) try beak.check(h.beak_namespace_mkdir(machine.namespace, beak.bytes(parent)));
            try writeBytes(machine, path, content);
            return .{ .written = try changeOf(arena, null, content, name) };
        },
        .not_text => {
            try writeBytes(machine, path, content);
            return .{ .written = try changeOf(arena, "", content, name) };
        },
        .text => |was| {
            const after = try text.replacing(arena, content, was);
            try writeBytes(machine, path, try text.bytesOf(arena, after, was));
            return .{ .written = try changeOf(arena, was.text, after, name) };
        },
    }
}

/// What an edit did: the change it made, with how many matches it replaced and by which tier it found them; why it was
/// refused; or that the path names nothing, a folder, or a file that is no text.
pub const Edit = union(enum) {
    made: struct { change: Change, replacements: usize, tier: text.Tier },
    refused: text.Refusal,
    missing,
    directory,
    not_text,
};

/// Edits the text file at `path` as `request` asks, its byte-order mark kept; nothing written where it is refused.
pub fn edit(machine: Machine, arena: Allocator, path: []const u8, request: text.Request, name: []const u8) beak.Error!Edit {
    const was = switch (try textFileOf(machine, arena, path)) {
        .text => |file| file,
        .missing => return .missing,
        .directory => return .directory,
        .not_text => return .not_text,
    };
    const made = switch (try text.edited(arena, was.text, request)) {
        .made => |made| made,
        .refused => |why| return .{ .refused = why },
    };
    try writeBytes(machine, path, try text.bytesOf(arena, made.text, was));
    return .{ .made = .{ .change = try changeOf(arena, was.text, made.text, name), .replacements = made.replacements, .tier = made.tier } };
}

/// A file as the tools that change one read it: its text; or that there is none, or a folder, or a file of no text.
const TextFile = union(enum) { text: text.Text, missing, directory, not_text };

fn textFileOf(machine: Machine, arena: Allocator, path: []const u8) beak.Error!TextFile {
    const stat = try statOf(machine, path) orelse return .missing;
    if (stat.type == h.BEAK_ENTRY_DIRECTORY) return .directory;
    const found = text.textOf(try readRange(machine, arena, path, 0, stat.size)) orelse return .not_text;
    return .{ .text = found };
}

fn statOf(machine: Machine, path: []const u8) beak.Error!?h.beak_stat {
    var stat: h.beak_stat = undefined;
    const status = h.beak_namespace_stat(machine.namespace, beak.bytes(path), &stat);
    if (status == h.BEAK_NOT_FOUND) return null;
    try beak.check(status);
    return stat;
}

fn readRange(machine: Machine, arena: Allocator, path: []const u8, offset: u64, length: u64) beak.Error![]const u8 {
    const allocator = beak.outputs(&arena);
    var bytes: h.beak_bytes = undefined;
    try beak.check(h.beak_namespace_read(machine.namespace, beak.bytes(path), offset, length, &allocator, &bytes));
    return beak.slice(bytes);
}

fn writeBytes(machine: Machine, path: []const u8, bytes: []const u8) beak.Error!void {
    try beak.check(h.beak_namespace_write(machine.namespace, beak.bytes(path), beak.bytes(bytes)));
}

/// The entries of the folder at `path`, every page of them.
fn listOf(machine: Machine, arena: Allocator, path: []const u8) beak.Error![]h.beak_dirent {
    var out: std.ArrayList(h.beak_dirent) = .empty;
    var after: ?[]const u8 = null;
    while (true) {
        const allocator = beak.outputs(&arena);
        var entries: [*c]h.beak_dirent = null;
        var count: usize = 0;
        const asked = (beak.Range{ .after = after, .limit = page_names }).asked();
        try beak.check(h.beak_namespace_list(machine.namespace, beak.bytes(path), &asked, &allocator, &entries, &count));
        const page = beak.items(h.beak_dirent, entries, count);
        try out.appendSlice(arena, page);
        if (page.len < page_names) return out.items;
        after = beak.slice(page[page.len - 1].name);
    }
}

const page_names = 256;

/// The folder a namespace's path is in; the root's, empty, for a name at the top.
fn parentOf(path: []const u8) []const u8 {
    return path[0 .. std.mem.lastIndexOfScalar(u8, path, '/') orelse 0];
}

fn joined(arena: Allocator, folder: []const u8, name: []const u8) error{OutOfMemory}![]const u8 {
    if (folder.len == 0) return name;
    return std.mem.concat(arena, u8, &.{ folder, "/", name });
}
