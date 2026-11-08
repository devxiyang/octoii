//! What a client follows, and how it is fed: each thread it follows from where its reader stands — the entries its log
//! appends, its state as it changes, its terminals as they come, take titles and go — the list of threads it watches, a
//! row of each thread as it changes, the settings it watches — the environment's and its device's — and each terminal
//! it follows in a view of its size, from the bytes it was sent up to. Each is marked as the commits the runtime's
//! journal tell of touch it, or as a terminal writes or is sized anew, and fed as the pump ends, while the client's
//! outbox has room; what would be sent is weighed against what was sent last, by a digest or an offset, so a mark that
//! changed nothing of it sends nothing.
const Following = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const Runtime = @import("../runtime.zig").Runtime;
const threads = @import("../threads.zig");
const log = threads.log;
const settings = @import("../settings.zig");
const Connection = @import("Connection.zig");
const Terminals = @import("../terminals.zig");
const terminals_ = @import("terminals.zig");
const pages_ = @import("pages.zig");
const Browser = @import("../browser.zig");

/// How many bytes of a log a thread followed is fed at a time, about.
pub const page_bytes = 256 << 10;

allocator: Allocator,
/// The threads followed, by their ids.
followed: std.StringArrayHashMapUnmanaged(Followed) = .empty,
/// The list of threads, where the client watches it.
listing: ?Listing = null,
/// The settings, where the client watches them.
settings_watch: ?SettingsWatch = null,
/// The terminals followed, by their ids, each with the size of the view the client shows it in and where it stands in it.
terminals: std.StringArrayHashMapUnmanaged(terminals_.Follow) = .empty,
/// The browser's pages followed, by their ids, each with the size of the view the client shows it in and the frame it
/// was sent last.
pages: std.StringArrayHashMapUnmanaged(pages_.Follow) = .empty,

/// A thread followed: where its reader stands, the digest of the state last sent, whether it may hold what the client
/// was not sent — it changed since, or a page is left — whether the client was sent what streamed of it before it
/// followed, as what streams after goes to it as it comes, and whether its terminals came, took titles or went since it
/// was told of them.
const Followed = struct {
    arena: std.heap.ArenaAllocator,
    cursor: ?log.Cursor = null,
    state: ?u64 = null,
    changed: bool = true,
    streams_sent: bool = false,
    terminals_changed: bool = true,
    pages_changed: bool = true,
};

/// The list of threads watched: the digest of each row last sent, by the thread's id; the threads changed since; and
/// whether every thread may have.
const Listing = struct {
    sent: std.StringHashMapUnmanaged(u64) = .empty,
    changed: std.StringArrayHashMapUnmanaged(void) = .empty,
    all: bool,
};

/// The settings watched: the digest of what the client was sent of them last, and whether they may have changed since.
const SettingsWatch = struct {
    sent: u64,
    changed: bool = false,

    /// Sends the settings where they differ from what the client was sent last, and marks them unchanged; settings
    /// that cannot be read stay marked, and are read again as the next pump ends.
    fn send(watch: *SettingsWatch, connection: *Connection, arena: Allocator) !void {
        const message = try settingsEvent(arena, try settingsOf(connection.clients.runtime, arena, connection.principal.?.session));
        const digest = std.hash.Wyhash.hash(0, message);
        if (digest != watch.sent) connection.send(message);
        watch.sent = digest;
        watch.changed = false;
    }
};

/// The settings as a client is told of them: the environment's, and those of the device that holds the client's session.
pub const Settings = struct { environment: settings.Environment, device: foundation.json.Raw };

/// The settings as they stand for the device that holds `session`.
pub fn settingsOf(runtime: *const Runtime, arena: Allocator, session: []const u8) !Settings {
    return .{ .environment = try settings.environmentOf(runtime.volume, &arena), .device = try settings.deviceOf(runtime.volume, &arena, session) };
}

/// Watches the settings as `now` says they stand, which the client is answered with: from here on, they are sent as
/// they change.
pub fn watchSettings(following: *Following, arena: Allocator, now: Settings) !void {
    following.settings_watch = .{ .sent = std.hash.Wyhash.hash(0, try settingsEvent(arena, now)) };
}

pub fn unwatchSettings(following: *Following) void {
    following.settings_watch = null;
}

/// Marks the settings watched as changed.
pub fn changedSettings(following: *Following) void {
    if (following.settings_watch) |*watch| watch.changed = true;
}

fn settingsEvent(arena: Allocator, now: Settings) ![]const u8 {
    return foundation.json.encode(arena, .{ .event = "settings", .environment = now.environment, .device = now.device });
}

pub fn deinit(following: *Following) void {
    for (following.followed.keys(), following.followed.values()) |id, *each| {
        following.allocator.free(id);
        each.arena.deinit();
    }
    following.followed.deinit(following.allocator);
    following.unwatchThreads();
    for (following.terminals.keys()) |id| following.allocator.free(id);
    following.terminals.deinit(following.allocator);
    for (following.pages.keys()) |id| following.allocator.free(id);
    following.pages.deinit(following.allocator);
}

/// Follows `id` in `map` — a terminal or a page shown in a view — as `value` says, its id copied where it was not
/// followed.
fn followIn(following: *Following, map: anytype, id: []const u8, value: anytype) !void {
    const slot = try map.getOrPut(following.allocator, id);
    if (!slot.found_existing) {
        slot.key_ptr.* = following.allocator.dupe(u8, id) catch |err| {
            map.swapRemoveAt(slot.index);
            return err;
        };
    }
    slot.value_ptr.* = value;
}

/// What `id` in `map`, which the client follows, is shown in a view of `size` now.
fn resizeIn(map: anytype, id: []const u8, size: anytype) !void {
    (map.getPtr(id) orelse return error.NotFollowed).size = size;
}

fn unfollowIn(following: *Following, map: anytype, id: []const u8) void {
    const removed = map.fetchSwapRemove(id) orelse return;
    following.allocator.free(removed.key);
}

/// Follows the terminal `id`, shown in a view of `size`, from `from`, the bytes it had written where the client stood,
/// or with its screen drawn where it stands nowhere, fed as the next pump ends.
pub fn followTerminal(following: *Following, id: []const u8, from: ?u64, size: Terminals.Size) !void {
    try following.followIn(&following.terminals, id, terminals_.Follow{ .size = size, .sent = from });
}

/// The terminal `id`, which the client follows, shown in a view of `size` now.
pub fn resizeTerminal(following: *Following, id: []const u8, size: Terminals.Size) !void {
    try resizeIn(&following.terminals, id, size);
}

pub fn unfollowTerminal(following: *Following, id: []const u8) void {
    following.unfollowIn(&following.terminals, id);
}

/// Follows the page `id`, shown in a view of `size`, its newest frame sent as the next pump ends.
pub fn followPage(following: *Following, id: []const u8, size: Browser.Size) !void {
    try following.followIn(&following.pages, id, pages_.Follow{ .size = size });
}

/// The page `id`, which the client follows, shown in a view of `size` now.
pub fn resizePage(following: *Following, id: []const u8, size: Browser.Size) !void {
    try resizeIn(&following.pages, id, size);
}

pub fn unfollowPage(following: *Following, id: []const u8) void {
    following.unfollowIn(&following.pages, id);
}

/// Marks the page `id`, where the client follows it, as painted anew.
pub fn changedPage(following: *Following, id: []const u8) void {
    if (following.pages.getPtr(id)) |each| each.changed = true;
}

/// Marks the pages of the thread `tid`, where the client follows it, as having come, changed or gone.
pub fn changedPages(following: *Following, tid: []const u8) void {
    if (following.followed.getPtr(tid)) |each| each.pages_changed = true;
}

/// Marks the terminal `id`, where the client follows it, as having written.
pub fn changedTerminal(following: *Following, id: []const u8) void {
    if (following.terminals.getPtr(id)) |each| each.changed = true;
}

/// Marks the terminal `id`, where the client follows it, to be drawn again whole.
pub fn redrawTerminal(following: *Following, id: []const u8) void {
    const each = following.terminals.getPtr(id) orelse return;
    each.sent = null;
    each.changed = true;
}

/// Marks the terminals of the thread `tid`, where the client follows it, as having come, taken titles or gone.
pub fn changedTerminals(following: *Following, tid: []const u8) void {
    if (following.followed.getPtr(tid)) |each| each.terminals_changed = true;
}

/// Follows the thread `tid`, from where the client's reader stood or from its start, fed as the next pump ends.
pub fn follow(following: *Following, runtime: *Runtime, arena: Allocator, tid: []const u8, from: ?log.Cursor) !void {
    const thread = try threads.pathOf(arena, tid);
    if (try runtime.volume.stat(&arena, thread) == null) return error.NoSuchThread;
    if (from) |stood| if (!try log.holds(runtime.volume, &arena, thread, stood)) return error.InvalidCursor;
    const slot = try following.followed.getOrPut(following.allocator, tid);
    if (slot.found_existing) {
        slot.value_ptr.arena.deinit();
    } else {
        slot.key_ptr.* = following.allocator.dupe(u8, tid) catch |err| {
            following.followed.swapRemoveAt(slot.index);
            return err;
        };
    }
    slot.value_ptr.* = .{ .arena = .init(following.allocator) };
    if (from) |stood| slot.value_ptr.cursor = .{ .segment = try slot.value_ptr.arena.allocator().dupe(u8, stood.segment), .offset = stood.offset };
}

pub fn unfollow(following: *Following, tid: []const u8) void {
    const removed = following.followed.fetchSwapRemove(tid) orelse return;
    following.allocator.free(removed.key);
    var arena = removed.value.arena;
    arena.deinit();
}

/// Whether the client follows the thread `tid` and was sent what streamed of it before, so what streams now goes to it.
pub fn streamsSent(following: *const Following, tid: []const u8) bool {
    const each = following.followed.get(tid) orelse return false;
    return each.streams_sent;
}

/// An event of what streams of the thread `tid` for its request `key`, by its offset in the stream.
pub fn streamEvent(arena: Allocator, tid: []const u8, key: []const u8, offset: u64, data: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll("{\"event\":\"stream\",\"thread\":");
    try std.json.Stringify.value(tid, .{}, &out.writer);
    try out.writer.writeAll(",\"request\":");
    try std.json.Stringify.value(key, .{}, &out.writer);
    try out.writer.print(",\"offset\":{d},\"data\":{s}}}", .{ offset, data });
    return out.written();
}

/// Watches the list of threads as `rows` say it stands now, which the client is answered with, as a list is watched
/// from the version it was read at: from here on, a row of each thread is sent as it changes.
pub fn watchThreads(following: *Following, arena: Allocator, rows: []const threads.Listed) !void {
    following.unwatchThreads();
    following.listing = .{ .all = false };
    errdefer following.unwatchThreads();
    for (rows) |row| _ = try following.recorded(arena, row);
}

pub fn unwatchThreads(following: *Following) void {
    const listing = if (following.listing) |*watched| watched else return;
    var sent = listing.sent.keyIterator();
    while (sent.next()) |id| following.allocator.free(id.*);
    listing.sent.deinit(following.allocator);
    for (listing.changed.keys()) |id| following.allocator.free(id);
    listing.changed.deinit(following.allocator);
    following.listing = null;
}

/// Marks what the client follows of the thread `tid` as changed: the thread followed, and its row in the list watched.
pub fn changed(following: *Following, tid: []const u8) void {
    if (following.followed.getPtr(tid)) |each| each.changed = true;
    const listing = if (following.listing) |*watched| watched else return;
    if (listing.all or listing.changed.contains(tid)) return;
    // A row that cannot be marked alone is sent with every other.
    const id = following.allocator.dupe(u8, tid) catch return following.changedAll();
    listing.changed.put(following.allocator, id, {}) catch {
        following.allocator.free(id);
        following.changedAll();
    };
}

/// Marks everything followed as changed, as a change at the root says.
pub fn changedAll(following: *Following) void {
    for (following.followed.values()) |*each| each.changed = true;
    for (following.terminals.values()) |*each| each.changed = true;
    for (following.pages.values()) |*each| each.changed = true;
    if (following.listing) |*listing| listing.all = true;
    following.changedSettings();
}

/// Feeds the client what changed of what it follows, through `connection`, while its outbox has room: the settings
/// watched, the rows of the list watched, a page of each thread followed, the terminals and the browser's pages of each
/// whose came, changed or went, the newest frame of each page followed, then what each terminal followed wrote, or its
/// screen drawn again. Whether a page is left to feed while it has room.
pub fn feed(following: *Following, connection: *Connection) bool {
    var arena_state: std.heap.ArenaAllocator = .init(following.allocator);
    defer arena_state.deinit();
    if (following.settings_watch) |*watch| if (watch.changed) {
        if (!connection.hasRoom()) return false;
        // Settings that cannot be read stay marked, and are read again as the next pump ends.
        watch.send(connection, arena_state.allocator()) catch {};
        _ = arena_state.reset(.retain_capacity);
    };
    if (following.listing != null) {
        if (!connection.hasRoom()) return false;
        // A list that cannot be read is read whole as the next pump ends.
        following.sendRows(connection, arena_state.allocator()) catch following.changedAll();
    }
    var left = false;
    for (following.followed.keys(), following.followed.values()) |tid, *each| {
        if (!each.changed) continue;
        // A follow that waits for room is fed once the host's taker makes some, which wakes the loop.
        if (!connection.hasRoom()) return false;
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        // A thread whose entries cannot be sent is told of, and sent them again once it changes.
        each.changed = sendEntries(connection, arena, tid, each) catch |err| failed: {
            const told = foundation.json.encode(arena, .{ .event = "failed", .thread = tid, .@"error" = .{ .code = "failed", .message = @errorName(err) } });
            connection.send(told catch break :failed false);
            break :failed false;
        };
        left = left or each.changed;
    }
    const terminals = connection.clients.terminals;
    for (following.followed.keys(), following.followed.values()) |tid, *each| {
        if (!each.terminals_changed) continue;
        if (!connection.hasRoom()) return false;
        _ = arena_state.reset(.retain_capacity);
        // Terminals that cannot be told of are told of as the next pump ends.
        connection.send(terminals_.listEvent(terminals, arena_state.allocator(), tid) catch continue);
        each.terminals_changed = false;
    }
    const browser = connection.clients.browser;
    for (following.followed.keys(), following.followed.values()) |tid, *each| {
        if (!each.pages_changed) continue;
        if (!connection.hasRoom()) return false;
        _ = arena_state.reset(.retain_capacity);
        // Pages that cannot be told of are told of as the next pump ends.
        connection.send(pages_.listEvent(browser, arena_state.allocator(), tid) catch continue);
        each.pages_changed = false;
    }
    for (following.pages.keys(), following.pages.values()) |id, *each| {
        if (!each.changed) continue;
        // A frame waits for room, the newest sent once there is.
        if (!connection.hasRoom()) return false;
        _ = arena_state.reset(.retain_capacity);
        // A frame that cannot be sent is sent as the next pump ends.
        pages_.send(browser, connection, arena_state.allocator(), id, each) catch {
            each.changed = true;
            left = true;
        };
    }
    for (following.terminals.keys(), following.terminals.values()) |id, *each| {
        if (!each.changed) continue;
        if (!connection.hasRoom()) return false;
        _ = arena_state.reset(.retain_capacity);
        // A terminal whose output cannot be read is drawn again as the next pump ends.
        terminals_.send(terminals, connection, arena_state.allocator(), id, each) catch {
            each.sent = null;
        };
        left = left or each.changed;
    }
    return left;
}

/// Sends a row of each thread changed since the rows were last sent, where its row changed; of every thread where every one
/// may have.
fn sendRows(following: *Following, connection: *Connection, arena: Allocator) !void {
    const listing = &following.listing.?;
    const runtime = connection.clients.runtime;
    if (listing.all) {
        listing.all = false;
        for (listing.changed.keys()) |id| following.allocator.free(id);
        listing.changed.clearRetainingCapacity();
        const rows = try threads.list(runtime, arena);
        var listed: std.StringHashMapUnmanaged(void) = .empty;
        for (rows) |row| {
            try listed.put(arena, row.id, {});
            try following.sendRow(connection, arena, row);
        }
        var gone: std.ArrayList([]const u8) = .empty;
        var told = listing.sent.keyIterator();
        while (told.next()) |id| if (!listed.contains(id.*)) try gone.append(arena, try arena.dupe(u8, id.*));
        for (gone.items) |id| try following.sendGone(connection, arena, id);
        return;
    }
    while (listing.changed.pop()) |marked| {
        defer following.allocator.free(marked.key);
        if (try threads.listedOf(runtime, arena, marked.key)) |row| {
            try following.sendRow(connection, arena, row);
        } else try following.sendGone(connection, arena, marked.key);
    }
}

/// Tells the client the thread `id` is gone, where it was told of it, and forgets it was.
fn sendGone(following: *Following, connection: *Connection, arena: Allocator, id: []const u8) !void {
    const listing = &following.listing.?;
    const told = listing.sent.fetchRemove(id) orelse return;
    defer following.allocator.free(told.key);
    connection.send(try foundation.json.encode(arena, .{ .event = "thread-gone", .thread = id }));
}

/// Sends the row of a thread, where it is not the row last sent of it.
fn sendRow(following: *Following, connection: *Connection, arena: Allocator, row: threads.Listed) !void {
    if (try following.recorded(arena, row)) |message| connection.send(message);
}

/// The message that tells of `row`, recorded as the row last told of its thread; null where it is that row already.
fn recorded(following: *Following, arena: Allocator, row: threads.Listed) !?[]const u8 {
    const listing = &following.listing.?;
    const message = try foundation.json.encode(arena, .{ .event = "thread", .thread = row });
    const digest = std.hash.Wyhash.hash(0, message);
    const slot = try listing.sent.getOrPut(following.allocator, row.id);
    if (slot.found_existing and slot.value_ptr.* == digest) return null;
    if (!slot.found_existing) slot.key_ptr.* = following.allocator.dupe(u8, row.id) catch |err| {
        listing.sent.removeByPtr(slot.key_ptr);
        return err;
    };
    slot.value_ptr.* = digest;
    return message;
}

/// Sends a page of the entries the thread `tid` appended since its reader stood, and its state where it changed once the
/// reader is at the log's end, so a state sent is that of the entries sent before it; whether a page is left.
fn sendEntries(connection: *Connection, arena: Allocator, tid: []const u8, followed: *Followed) !bool {
    const runtime = connection.clients.runtime;
    const thread = try threads.pathOf(arena, tid);
    const found = try log.readFrom(runtime.volume, &arena, thread, followed.cursor, page_bytes);
    if (found.lines.len > 0) {
        var out: std.Io.Writer.Allocating = .init(arena);
        try out.writer.writeAll("{\"event\":\"entries\",\"thread\":");
        try std.json.Stringify.value(tid, .{}, &out.writer);
        try out.writer.writeAll(",\"entries\":[");
        for (found.lines, 0..) |line, index| {
            if (index > 0) try out.writer.writeByte(',');
            try out.writer.writeAll(line);
        }
        try out.writer.writeAll("],\"cursor\":");
        try std.json.Stringify.value(found.cursor, foundation.json.options, &out.writer);
        try out.writer.writeByte('}');
        connection.send(out.written());
    }
    if (found.cursor) |cursor| {
        const segment = if (followed.cursor) |stood| (if (std.mem.eql(u8, stood.segment, cursor.segment)) stood.segment else null) else null;
        followed.cursor = .{ .segment = segment orelse try followed.arena.allocator().dupe(u8, cursor.segment), .offset = cursor.offset };
    }
    if (found.more) return true;
    const now = try foundation.json.encode(arena, .{ .event = "state", .thread = tid, .state = try threads.state(runtime, arena, tid) });
    const digest = std.hash.Wyhash.hash(0, now);
    if (followed.state != digest) {
        followed.state = digest;
        connection.send(now);
    }
    // Then what streamed of the thread before it was followed, each stream from its start; what streams after goes as
    // it comes.
    if (!followed.streams_sent) {
        followed.streams_sent = true;
        for (runtime.streams.by_key.keys(), runtime.streams.by_key.values()) |key, stream| {
            if (!std.mem.eql(u8, stream.topic, tid)) continue;
            for (stream.kept.items, 0..) |data, offset| connection.send(try streamEvent(arena, tid, key, offset, data));
        }
    }
    return false;
}
