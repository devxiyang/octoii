//! Beak through `beak.h`: its types as translated, what every call needs — text and bytes as `beak_bytes`, a status as
//! an error, an allocator Beak gives back through — and the calls Siphon makes on its volume, which Beak serializes,
//! so any task may make one.
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const h = @import("beak_h");

/// Beak's failures, one for each of its statuses but `BEAK_OK`.
pub const Error = error{
    Invalid,
    NoSuchHandle,
    Unsupported,
    NotFound,
    Exists,
    NotADirectory,
    IsADirectory,
    TooLarge,
    ReadOnly,
    Busy,
    Refused,
    Stale,
    Io,
    OutOfMemory,
};

/// `status` as nothing where it is `BEAK_OK`, else as its error.
pub fn check(status: h.beak_status) Error!void {
    return switch (status) {
        h.BEAK_OK => {},
        h.BEAK_INVALID => error.Invalid,
        h.BEAK_NO_SUCH_HANDLE => error.NoSuchHandle,
        h.BEAK_UNSUPPORTED => error.Unsupported,
        h.BEAK_NOT_FOUND => error.NotFound,
        h.BEAK_EXISTS => error.Exists,
        h.BEAK_NOT_A_DIRECTORY => error.NotADirectory,
        h.BEAK_IS_A_DIRECTORY => error.IsADirectory,
        h.BEAK_TOO_LARGE => error.TooLarge,
        h.BEAK_READ_ONLY => error.ReadOnly,
        h.BEAK_BUSY => error.Busy,
        h.BEAK_REFUSED => error.Refused,
        h.BEAK_STALE => error.Stale,
        h.BEAK_OUT_OF_MEMORY => error.OutOfMemory,
        else => error.Io,
    };
}

/// The status `err` stands for.
fn statusOf(err: Error) h.beak_status {
    return switch (err) {
        error.Invalid => h.BEAK_INVALID,
        error.NoSuchHandle => h.BEAK_NO_SUCH_HANDLE,
        error.Unsupported => h.BEAK_UNSUPPORTED,
        error.NotFound => h.BEAK_NOT_FOUND,
        error.Exists => h.BEAK_EXISTS,
        error.NotADirectory => h.BEAK_NOT_A_DIRECTORY,
        error.IsADirectory => h.BEAK_IS_A_DIRECTORY,
        error.TooLarge => h.BEAK_TOO_LARGE,
        error.ReadOnly => h.BEAK_READ_ONLY,
        error.Busy => h.BEAK_BUSY,
        error.Refused => h.BEAK_REFUSED,
        error.Stale => h.BEAK_STALE,
        error.Io => h.BEAK_IO,
        error.OutOfMemory => h.BEAK_OUT_OF_MEMORY,
    };
}

/// The failure `err` tells, as `failed` tells a status: its code, then the reason and the detail Beak gave, where the
/// thread's last call failed with it — so a work of several calls tells the one of them that failed.
pub fn told(arena: Allocator, err: Error) Allocator.Error![]const u8 {
    const status = statusOf(err);
    var failure: h.beak_error = undefined;
    h.beak_last_error(&failure);
    if (failure.code != status) return codeOf(status);
    return (try failed(arena, status)).?;
}

/// `status` as nothing where it is `BEAK_OK`, else as the failure Beak tells of it, raw, read at once from the
/// thread's last failure, as errno is read right after the call that set it: its code, then its reason and detail
/// where it has them, and the offset where a pattern failed — `invalid: bad-pattern: missing ) (offset 5)`.
pub fn failed(arena: Allocator, status: h.beak_status) Allocator.Error!?[]const u8 {
    if (status == h.BEAK_OK) return null;
    var failure: h.beak_error = undefined;
    h.beak_last_error(&failure);
    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    writer.writeAll(codeOf(status)) catch return error.OutOfMemory;
    for ([_]h.beak_bytes{ failure.reason, failure.detail }) |part| {
        if (part.len > 0) writer.print(": {s}", .{slice(part)}) catch return error.OutOfMemory;
    }
    if (get(failure.offset)) |offset| writer.print(" (offset {d})", .{offset}) catch return error.OutOfMemory;
    return out.written();
}

/// Why the thread's last call failed, as Beak names it — a refusal's own reason, else the error's name — read at once
/// after the call, as errno is.
pub fn lastReason() []const u8 {
    var failure: h.beak_error = undefined;
    h.beak_last_error(&failure);
    return slice(failure.reason);
}

/// The name of `status`, as Beak's boundary names its codes.
fn codeOf(status: h.beak_status) []const u8 {
    return switch (status) {
        h.BEAK_INVALID => "invalid",
        h.BEAK_NO_SUCH_HANDLE => "no-such-handle",
        h.BEAK_UNSUPPORTED => "unsupported",
        h.BEAK_NOT_FOUND => "not-found",
        h.BEAK_EXISTS => "exists",
        h.BEAK_NOT_A_DIRECTORY => "not-a-directory",
        h.BEAK_IS_A_DIRECTORY => "is-a-directory",
        h.BEAK_TOO_LARGE => "too-large",
        h.BEAK_READ_ONLY => "read-only",
        h.BEAK_BUSY => "busy",
        h.BEAK_REFUSED => "refused",
        h.BEAK_STALE => "stale",
        h.BEAK_OUT_OF_MEMORY => "out-of-memory",
        else => "io",
    };
}

pub fn bytes(text: []const u8) h.beak_bytes {
    return .{ .ptr = text.ptr, .len = text.len };
}

/// Each of `texts` as `beak_bytes`, in `arena`.
pub fn bytesAll(arena: Allocator, texts: []const []const u8) Allocator.Error![]h.beak_bytes {
    const out = try arena.alloc(h.beak_bytes, texts.len);
    for (texts, out) |text, *each| each.* = bytes(text);
    return out;
}

pub fn slice(given: h.beak_bytes) []const u8 {
    return if (given.len == 0) "" else given.ptr[0..given.len];
}

/// Which names of a directory a page of its listing holds — a volume's or a namespace's alike: those starting with
/// `prefix`, past `after` in the direction read, at most `limit`.
pub const Range = struct {
    prefix: []const u8 = "",
    after: ?[]const u8 = null,
    reverse: bool = false,
    limit: usize,

    /// The range as Beak is asked it.
    pub fn asked(range: Range) h.beak_range {
        return .{ .prefix = bytes(range.prefix), .has_after = range.after != null, .after = bytes(range.after orelse ""), .reverse = range.reverse, .limit = range.limit };
    }
};

/// The `count` items Beak gave at `pointer`, as a slice: none where it gave none, and so maybe no pointer.
pub fn items(comptime T: type, pointer: [*c]const T, count: usize) []const T {
    return if (count == 0) &.{} else pointer[0..count];
}

pub fn optional(value: ?i64) h.beak_optional {
    return if (value) |set| .{ .set = true, .value = set } else .{ .set = false, .value = 0 };
}

pub fn get(value: h.beak_optional) ?i64 {
    return if (value.set) value.value else null;
}

/// An allocator Beak gives back through, over `arena`, which outlives the call and what it gave.
pub fn outputs(arena: *const Allocator) h.beak_allocator {
    return .{ .context = @ptrCast(@constCast(arena)), .alloc = allocate };
}

fn allocate(context: ?*anyopaque, len: usize, alignment: usize) callconv(.c) ?*anyopaque {
    const arena: *const Allocator = @ptrCast(@alignCast(context.?));
    return arena.rawAlloc(@max(len, 1), .fromByteUnits(alignment), @returnAddress());
}

/// What Beak's `given` allocates, as an allocator that never frees: a phase's arena.
pub fn allocatorOf(given: [*c]const h.beak_allocator) Allocator {
    return .{ .ptr = @ptrCast(@constCast(given)), .vtable = &given_vtable };
}

const given_vtable: Allocator.VTable = .{ .alloc = givenAlloc, .resize = Allocator.noResize, .remap = Allocator.noRemap, .free = Allocator.noFree };

fn givenAlloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    const given: *const h.beak_allocator = @ptrCast(@alignCast(context));
    return @ptrCast(given.alloc.?(given.context, @max(len, 1), alignment.toByteUnits()));
}

/// `path` and `name` joined by `/`; `name` alone at the root.
pub fn join(arena: Allocator, path: []const u8, name: []const u8) Allocator.Error![]const u8 {
    return if (path.len == 0) arena.dupe(u8, name) else std.mem.concat(arena, u8, &.{ path, "/", name });
}

/// The child process `key` of the process or directory at `parent`, as Beak names it.
pub fn childPath(arena: Allocator, parent: []const u8, key: []const u8) Allocator.Error![]const u8 {
    return join(arena, parent, try std.mem.concat(arena, u8, &.{ h.BEAK_PROCESS_KIND, ":", key }));
}

/// The key of the process at `path`: its name past its kind.
pub fn keyOf(path: []const u8) []const u8 {
    const name = path[if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| slash + 1 else 0..];
    return name[if (std.mem.indexOfScalar(u8, name, ':')) |colon| colon + 1 else 0..];
}

/// The value of the label `name` among `labels`; null where it is not there.
pub fn labelOf(labels: [*c]const h.beak_label, count: usize, name: []const u8) ?[]const u8 {
    for (items(h.beak_label, labels, count)) |label| if (std.mem.eql(u8, slice(label.name), name)) return slice(label.value);
    return null;
}

/// The value of the annotation `name` on the directory an entry shows; null where it carries none, or is no directory.
pub fn annotationOf(entry: *const h.beak_entry, name: []const u8) ?[]const u8 {
    const directory = entry.directory orelse return null;
    return labelOf(directory.*.annotations, directory.*.annotation_count, name);
}

/// How the process an entry shows ended; null for one that lives, or for any other entry.
pub fn outcomeOf(entry: *const h.beak_entry) ?*const h.beak_outcome {
    const directory = entry.directory orelse return null;
    const process = directory.*.process orelse return null;
    return process.*.outcome;
}

/// A volume, by its handle.
pub const Volume = struct {
    handle: h.beak_handle,

    pub fn open(device: h.beak_device, time: i64) Error!Volume {
        const options: h.beak_volume_options = .{ .time = time, .running_max = 0, .term_grace_ms = optional(null), .zombie_retention_ms = optional(null) };
        var handle: h.beak_handle = 0;
        try check(h.beak_volume_open(&device, &options, &handle));
        return .{ .handle = handle };
    }

    pub fn close(volume: Volume) void {
        _ = h.beak_close(volume.handle);
    }

    /// Commits `changes` at `time`, in the system's hands as it returns; its sequence number.
    pub fn commit(volume: Volume, time: i64, changes: []const h.beak_change) Error!u64 {
        var seq: u64 = 0;
        try check(h.beak_volume_commit(volume.handle, time, changes.ptr, changes.len, &seq));
        return seq;
    }

    /// Makes every commit so far survive a power loss; syncs that wait on one another share the first.
    pub fn sync(volume: Volume) Error!void {
        try check(h.beak_volume_sync(volume.handle));
    }

    /// The bytes the volume keeps on its device, live or not, as `du` counts them.
    pub fn usage(volume: Volume) Error!u64 {
        var usage_: h.beak_usage = undefined;
        try check(h.beak_volume_usage(volume.handle, &usage_));
        return usage_.bytes;
    }

    /// Gives back what the volume's root no longer reaches, at `time`, the volume taking no commit meanwhile: how many
    /// objects it kept and how many it forgot.
    pub fn collect(volume: Volume, time: i64) Error!h.beak_collected {
        var collected: h.beak_collected = undefined;
        try check(h.beak_volume_collect(volume.handle, time, null, 0, &collected));
        return collected;
    }

    /// A new id, minted at `time`: later than every one the volume minted before.
    pub fn mint(volume: Volume, time: i64) Error![36]u8 {
        var id: h.beak_id = undefined;
        try check(h.beak_volume_mint(volume.handle, time, &id));
        return id.text;
    }

    /// The entry at `path`, in `arena`; null where there is none.
    pub fn stat(volume: Volume, arena: *const Allocator, path: []const u8) Error!?*const h.beak_entry {
        const allocator = outputs(arena);
        var entry: [*c]h.beak_entry = null;
        const status = h.beak_volume_stat(volume.handle, bytes(path), &allocator, &entry);
        if (status == h.BEAK_NOT_FOUND) return null;
        try check(status);
        return entry;
    }

    /// The entries of the directory at `path` whose names start with `prefix`, every one, page by page, in `arena`;
    /// none where there is no directory.
    pub fn list(volume: Volume, arena: *const Allocator, path: []const u8, prefix: []const u8) Error![]const h.beak_entry {
        var out: std.ArrayList(h.beak_entry) = .empty;
        var after: ?[]const u8 = null;
        while (true) {
            const found = try volume.page(arena, path, .{ .prefix = prefix, .after = after, .limit = page_entries });
            try out.appendSlice(arena.*, found);
            if (found.len < page_entries) return out.items;
            after = slice(found[found.len - 1].name);
        }
    }

    /// A page of the directory at `path`, as `range` picks it, in `arena`: fewer than its limit where the directory holds
    /// no more, or Beak's bound on a reply comes first; none where there is no directory.
    pub fn page(volume: Volume, arena: *const Allocator, path: []const u8, range: Range) Error![]const h.beak_entry {
        const allocator = outputs(arena);
        const given = range.asked();
        var entries: [*c]h.beak_entry = null;
        var count: usize = 0;
        const status = h.beak_volume_list(volume.handle, bytes(path), &given, &allocator, &entries, &count);
        if (status == h.BEAK_NOT_FOUND) return &.{};
        try check(status);
        return items(h.beak_entry, entries, count);
    }

    /// A label a directory carries, as the label index finds it: by its name, of the value given, or of any where it is
    /// empty.
    pub const Label = struct { name: []const u8, value: []const u8 = "" };

    /// The directories of `kind` under `under` that carry `label`, every one, page by page, in path order, each with
    /// its path, in `arena`.
    pub fn find(volume: Volume, arena: *const Allocator, kind: []const u8, label: Label, under: []const u8) Error![]const h.beak_entry {
        const allocator = outputs(arena);
        var out: std.ArrayList(h.beak_entry) = .empty;
        var after: ?[]const u8 = null;
        while (true) {
            var entries: [*c]h.beak_entry = null;
            var count: usize = 0;
            const carried: h.beak_label = .{ .name = bytes(label.name), .value = bytes(label.value) };
            try check(h.beak_volume_find(volume.handle, bytes(kind), carried, bytes(under), after != null, bytes(after orelse ""), page_entries, &allocator, &entries, &count));
            try out.appendSlice(arena.*, items(h.beak_entry, entries, count));
            if (count < page_entries) return out.items;
            after = slice(entries[count - 1].path);
        }
    }

    /// The bytes of the file at `path` from `offset`, at most `length`, in `arena`.
    pub fn read(volume: Volume, arena: *const Allocator, path: []const u8, offset: u64, length: u64) Error![]const u8 {
        const allocator = outputs(arena);
        var read_bytes: h.beak_bytes = undefined;
        try check(h.beak_volume_read(volume.handle, bytes(path), offset, length, &allocator, &read_bytes));
        return slice(read_bytes);
    }

    /// The whole of the file at `path`, in `arena`.
    pub fn readAll(volume: Volume, arena: *const Allocator, path: []const u8) Error![]const u8 {
        return volume.read(arena, path, 0, std.math.maxInt(u64));
    }

    /// What the volume's journal holds after a commit: its change sets, in order; the oldest commit it keeps; and the
    /// latest commit.
    pub const Journal = struct { sets: []const h.beak_change_set, oldest: ?u64, latest: u64 };

    /// The change sets after the commit `after`, at most `limit`, in `arena`, with the journal's oldest and latest
    /// commits.
    pub fn journal(volume: Volume, arena: *const Allocator, after: u64, limit: usize) Error!Journal {
        const allocator = outputs(arena);
        var sets: [*c]h.beak_change_set = null;
        var count: usize = 0;
        var oldest: h.beak_optional = undefined;
        var latest: u64 = 0;
        try check(h.beak_volume_changes(volume.handle, after, limit, &allocator, &sets, &count, &oldest, &latest));
        return .{ .sets = items(h.beak_change_set, sets, count), .oldest = if (get(oldest)) |seq| @intCast(seq) else null, .latest = latest };
    }

    /// The ways the journal's changes after a commit met a set of selectors: each match, in order; the last commit read,
    /// from which a reader reads on; the oldest commit the journal keeps; and the latest commit.
    pub const Matches = struct { matches: []const h.beak_match, through: u64, oldest: ?u64, latest: u64 };

    /// The ways the changes after the commit `after` met `selectors`, the change sets read at most `limit`, in `arena`:
    /// a watch through selectors, read on from `through`.
    pub fn matches(volume: Volume, arena: *const Allocator, after: u64, limit: usize, selectors: []const h.beak_selector) Error!Matches {
        const allocator = outputs(arena);
        var matched: [*c]h.beak_match = null;
        var count: usize = 0;
        var through: u64 = 0;
        var oldest: h.beak_optional = undefined;
        var latest: u64 = 0;
        try check(h.beak_volume_matches(volume.handle, after, limit, selectors.ptr, selectors.len, &allocator, &matched, &count, &through, &oldest, &latest));
        return .{ .matches = items(h.beak_match, matched, count), .through = through, .oldest = if (get(oldest)) |seq| @intCast(seq) else null, .latest = latest };
    }

    const page_entries = 256;
};

test "a watch through selectors tells the directories a selector picks, and where to read on from" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const volume = try Volume.open(.{ .type = h.BEAK_DEVICE_MEMORY, .path = bytes("") }, 1);
    defer volume.close();
    var board = std.mem.zeroes(h.beak_change);
    board.type = h.BEAK_CHANGE_MKDIR;
    board.path = bytes("notes.board:1");
    var shelf = board;
    shelf.path = bytes("notes.shelf:2");
    const seq = try volume.commit(10, &.{ board, shelf });
    const kinds = [_]h.beak_bytes{bytes("notes.board")};
    var selector = std.mem.zeroes(h.beak_selector);
    selector.kinds = &kinds;
    selector.kind_count = kinds.len;
    selector.scope = h.BEAK_SCOPE_UNDER;
    const found = try volume.matches(&arena, 0, 10, &.{selector});
    try std.testing.expectEqual(seq, found.through);
    try std.testing.expectEqual(1, found.matches.len);
    try std.testing.expectEqual(@as(h.beak_match_how, h.BEAK_MATCH_WRITTEN), found.matches[0].how);
    try std.testing.expectEqualStrings("notes.board:1", slice(found.matches[0].path));
    try std.testing.expectEqual(0, (try volume.matches(&arena, found.through, 10, &.{selector})).matches.len);
}
