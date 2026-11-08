//! The files of the machine the host runs on, as a client reads them — as `ls`, `cat` and a fuzzy finder read a file
//! system: the names in a folder that begin with what is asked, a page at a time, those starting with a dot left out
//! unless asked for, each with what it names and whether its repository's ignore files leave it out; a page of what a
//! file holds — its lines, the image or the PDF it is, or that it is binary; and the files and folders under a folder
//! whose paths hold what is asked for, best first. Each is an act on the machine, as `on_machine` does one.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const beak = @import("../beak.zig");
const h = beak.h;
const Machine = @import("../machine.zig");
const threads = @import("../threads.zig");
const text = @import("../text.zig");
const on_machine = @import("on_machine.zig");
const fuzzy = @import("fuzzy.zig");

/// The names in a folder that begin with `prefix`, a page of them: from the first, or past the name `after`; hidden
/// ones, starting with a dot, only where asked for.
pub const list = on_machine.method(listFolder);
/// A page of what a file holds: its lines from `offset`, the first from 1, `limit` of them at most.
pub const read = on_machine.method(readFile);
/// The files and folders under a folder whose paths hold what is asked for, best first, `limit` of them at most.
pub const search = on_machine.method(searchFolder);

const ListGiven = struct { path: []const u8, prefix: []const u8 = "", after: ?[]const u8 = null, hidden: bool = false };

/// What a name in a folder names.
const Kind = enum { directory, file, link };

/// A name in a folder: what it names, and whether its repository's ignore files leave it out, as git's check-ignore says.
const Entry = struct { name: []const u8, kind: Kind, ignored: bool };

/// A page of a folder's names: the folder, whole and clean; its names, in order; and whether more follow the last.
const Listed = struct { path: []const u8, entries: []const Entry, more: bool };

/// How many names a page of a folder holds at most; and how many each read of it asks of the machine, within what a
/// reply of Beak's holds, so a read that gives fewer is the folder's end.
const page_names = 1000;
const read_names = 256;

fn listFolder(arena: Allocator, on: on_machine.On, given: ListGiven) !Listed {
    const machine = on.machine;
    const folder = try Machine.paths.resolve(arena, machine.base, given.path);
    // Read on till a page and one more are kept, the names a page leaves out passed over, as `ls` passes over them.
    var kept: std.ArrayList(h.beak_dirent) = .empty;
    var after = given.after;
    while (kept.items.len <= page_names) {
        const read_now = try machine.page(&arena, folder, .{ .prefix = given.prefix, .after = after, .limit = read_names });
        for (read_now) |entry| if (given.hidden or !isHidden(beak.slice(entry.name))) try kept.append(arena, entry);
        if (read_now.len < read_names) break;
        after = beak.slice(read_now[read_now.len - 1].name);
    }
    const shown = kept.items[0..@min(kept.items.len, page_names)];
    const names = try arena.alloc([]const u8, shown.len);
    for (shown, names) |entry, *name| name.* = beak.slice(entry.name);
    const ignored = try arena.alloc(bool, shown.len);
    try machine.checkIgnore(arena, folder, names, ignored);
    const entries = try arena.alloc(Entry, shown.len);
    for (shown, names, ignored, entries) |entry, name, left_out, *each| each.* = .{ .name = name, .kind = kindOf(entry.type), .ignored = left_out };
    return .{ .path = folder, .entries = entries, .more = kept.items.len > page_names };
}

/// Whether a name is hidden, as `ls` hides it: it starts with a dot.
fn isHidden(name: []const u8) bool {
    return name.len > 0 and name[0] == '.';
}

fn kindOf(entry_type: h.beak_entry_type) Kind {
    return switch (entry_type) {
        h.BEAK_ENTRY_DIRECTORY => .directory,
        h.BEAK_ENTRY_LINK => .link,
        else => .file,
    };
}

/// What a read is given: the file, where its page begins and how many lines it holds; and the box an image is fitted
/// to, as a person's view draws it small — whole where none is given.
const ReadGiven = struct { path: []const u8, offset: ?u64 = null, limit: ?u64 = null, box: ?threads.stored.Box = null };

/// A page of a file, by what it holds: lines of text, from the first given, and whether more follow — with how many
/// lines it has where the page reached its end; an image or a PDF, each its bytes in base64; or that it is binary. Each
/// with the file, whole and clean, and its length in bytes.
const Page = union(enum) {
    text: struct { type: enum { text } = .text, path: []const u8, size: u64, from: u64, lines: []const []const u8, more: bool, line_count: ?u64 = null },
    image: struct { type: enum { image } = .image, path: []const u8, size: u64, media_type: []const u8, data: foundation.json.Base64 },
    pdf: struct { type: enum { pdf } = .pdf, path: []const u8, size: u64, data: foundation.json.Base64 },
    binary: struct { type: enum { binary } = .binary, path: []const u8, size: u64 },

    pub const jsonStringify = foundation.json.Variants(@This(), "type").jsonStringify;
};

/// A page's bounds, as a person reads a file where the model reads less: how many lines unless fewer are asked for,
/// and at most; the bytes its lines take, and a line's characters, past which it is cut; and how large an image or a
/// PDF given whole may be — an image fitted to a box as large as a file kept, as what is given of it is small.
const lines_given = 5000;
const lines_max = 20_000;
const page_bytes_max = 2 << 20;
const line_chars_max = 10_000;
const media_bytes_max = 8 << 20;

fn readFile(arena: Allocator, on: on_machine.On, given: ReadGiven) !Page {
    const machine = on.machine;
    const bounds: text.Bounds = .{ .offset = @max(1, given.offset orelse 1), .limit = @min(given.limit orelse lines_given, lines_max), .bytes_max = page_bytes_max, .line_chars_max = line_chars_max };
    const found = try machine.readFile(arena, try machine.pathOf(arena, given.path), .{ .bounds = bounds, .media_bytes_max = if (given.box == null) media_bytes_max else threads.stored.bytes_max });
    const path = try std.mem.concat(arena, u8, &.{ Machine.root, found.pathOf() });
    return switch (found) {
        .text => |page| .{ .text = .{ .path = path, .size = page.size, .from = page.from, .lines = try linesOf(arena, page.lines), .more = page.more, .line_count = page.line_count } },
        .image => |image| imagePage(arena, path, image, given.box),
        .pdf => |pdf| .{ .pdf = .{ .path = path, .size = pdf.size, .data = .{ .bytes = pdf.bytes } } },
        .binary => |binary| .{ .binary = .{ .path = path, .size = binary.size } },
        .directory => error.IsADirectory,
        .past_end => error.Invalid,
        .too_large => error.TooLarge,
    };
}

/// An image read as a person's view draws it: fitted to `box` where one is given, else as it is.
fn imagePage(arena: Allocator, path: []const u8, image: Machine.files.Media, box: ?threads.stored.Box) !Page {
    const drawn = if (box) |each| try threads.stored.pictureOf(arena, image.bytes, each) else null;
    return .{ .image = .{
        .path = path,
        .size = image.size,
        .media_type = if (drawn) |picture| picture.media_type else image.media_type,
        .data = .{ .bytes = if (drawn) |picture| picture.bytes else image.bytes },
    } };
}

fn linesOf(arena: Allocator, lines: []const text.Line) ![]const []const u8 {
    const texts = try arena.alloc([]const u8, lines.len);
    for (texts, lines) |*each, line| each.* = line.text;
    return texts;
}

const SearchGiven = struct { path: []const u8, query: []const u8, limit: ?u32 = null };

/// A file or a folder found, by its path from the folder searched.
const Found = struct { path: []const u8, kind: enum { file, directory } };

/// What a search found: the folder searched, whole and clean; the paths under it that match, best first, weighed among
/// every file under it; and whether more matched than are given.
const Searched = struct { path: []const u8, entries: []const Found, truncated: bool };

/// How many paths a search gives unless fewer are asked for, and at most.
const found_given = 50;
const found_max = 500;

fn searchFolder(arena: Allocator, on: on_machine.On, given: SearchGiven) !Searched {
    const machine = on.machine;
    const folder = try Machine.paths.resolve(arena, machine.base, given.path);
    const under = try machine.pathOf(arena, folder);
    var stat: h.beak_stat = undefined;
    try beak.check(h.beak_namespace_stat(machine.namespace, beak.bytes(under), &stat));
    if (stat.type != h.BEAK_ENTRY_DIRECTORY) return error.NotADirectory;
    const excludes = try beak.bytesAll(arena, try machine.excludesOf(arena, folder));
    var walk = std.mem.zeroes(h.beak_walk);
    walk.hidden = true;
    walk.excludes = excludes.ptr;
    walk.exclude_count = excludes.len;
    const allocator = beak.outputs(&arena);
    var walked: h.beak_found_files = undefined;
    try beak.check(h.beak_namespace_glob(machine.namespace, beak.bytes(under), &walk, &allocator, &walked));
    var candidates: Candidates = .{ .arena = arena, .query = given.query };
    for (beak.items(h.beak_bytes, walked.files, walked.count)) |file| try candidates.addFile(fromFolder(under, beak.slice(file)));
    const best = try candidates.best(@min(given.limit orelse found_given, found_max));
    return .{ .path = folder, .entries = best.found, .truncated = best.more };
}

/// `path`, a path of the machine's namespace under the folder `under`, as a path from it.
fn fromFolder(under: []const u8, path: []const u8) []const u8 {
    return if (under.len == 0) path else path[under.len + 1 ..];
}

/// The paths a search weighs — each file a walk found, and each folder on the way to one — with how well each matches.
const Candidates = struct {
    arena: Allocator,
    query: []const u8,
    matched: std.ArrayList(Scored) = .empty,
    /// The folders weighed already.
    folders: std.StringHashMapUnmanaged(void) = .empty,

    const Scored = struct { found: Found, score: i32 };

    /// Weighs the file at `path`, and each folder on the way to it not weighed yet.
    fn addFile(candidates: *Candidates, path: []const u8) !void {
        try candidates.add(.{ .path = path, .kind = .file });
        var end = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
        while (true) {
            const folder = path[0..end];
            if ((try candidates.folders.getOrPut(candidates.arena, folder)).found_existing) return;
            try candidates.add(.{ .path = folder, .kind = .directory });
            end = std.mem.lastIndexOfScalar(u8, folder, '/') orelse return;
        }
    }

    fn add(candidates: *Candidates, found: Found) !void {
        const score = fuzzy.score(found.path, candidates.query) orelse return;
        try candidates.matched.append(candidates.arena, .{ .found = found, .score = score });
    }

    /// The `limit` paths that match best — the highest score, then the shortest path, then in order — and whether more
    /// match.
    fn best(candidates: *Candidates, limit: usize) !struct { found: []const Found, more: bool } {
        const matched = candidates.matched.items;
        std.mem.sortUnstable(Scored, matched, {}, better);
        const kept = matched[0..@min(matched.len, limit)];
        const found = try candidates.arena.alloc(Found, kept.len);
        for (kept, found) |each, *path| path.* = each.found;
        return .{ .found = found, .more = matched.len > limit };
    }

    fn better(_: void, a: Scored, b: Scored) bool {
        if (a.score != b.score) return a.score > b.score;
        if (a.found.path.len != b.found.path.len) return a.found.path.len < b.found.path.len;
        return std.mem.lessThan(u8, a.found.path, b.found.path);
    }
};

test {
    _ = fuzzy;
}
