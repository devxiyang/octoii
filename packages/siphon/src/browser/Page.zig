//! A page of a thread's in the browser, as a tab is: its id, and the key the browser's answers name it by; how it
//! stands with the target that shows it; where it is and what it is called; whether it loads; its history; the size it
//! is laid out at; whether the browser is to paint it, and the newest frame it painted; where it is to go once it is
//! attached. And what the threads' agents read of it: the document it shows, by the id of the load that made it, and
//! whether it loaded; the document its snapshot was taken of; the dialog that holds it; the newest messages of its
//! console; and what waits for it to load, each told as it loaded or as it went. The loop alone touches it.
const Page = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

id: []const u8,
thread: []const u8,
key: u64,
link: Link = .none,
url: []const u8,
title: []const u8 = "",
loading: bool = false,
/// Its history: each entry's id, and the one it stands at.
history: []const i64 = &.{},
at: usize = 0,
size: Size,
casting: bool = false,
frame: ?Frame = null,
going: ?[]const u8 = null,
document: ?[]const u8 = null,
loaded: bool = false,
snapshot: ?[]const u8 = null,
dialog: ?Dialog = null,
/// The newest messages, oldest first, past `messages_max` the oldest let go of; and how many it ever had.
messages: std.ArrayList(Message) = .empty,
messages_told: u64 = 0,
/// The number of the newest message an agent read.
messages_read: u64 = 0,
awaiting: std.ArrayList(Awaiting) = .empty,

/// A view's size: CSS pixels across and down, and how many device pixels each CSS pixel is drawn with.
pub const Size = struct {
    width: u32,
    height: u32,
    scale: f32 = 1,

    /// The size two views both show whole: the smaller of each side, drawn at the finer scale.
    pub fn fitting(a: Size, b: Size) Size {
        return .{ .width = @min(a.width, b.width), .height = @min(a.height, b.height), .scale = @max(a.scale, b.scale) };
    }
};

/// A frame of a page as the browser painted it: JPEG, written in base64; its size in CSS pixels; its number among the
/// page's.
pub const Frame = struct { data: []const u8, width: u32, height: u32, number: u64 };

/// How a page stands with the target that shows it: none, as the browser that held it ended; asked for, the browser
/// making it; made, the browser's answer naming it before the browser attached to it; attached by its session, set
/// up and let run.
pub const Link = union(enum) {
    none,
    asked,
    made: []const u8,
    attached: struct { target: []const u8, session: []const u8 },

    /// The target, where the browser named it.
    pub fn target(link: Link) ?[]const u8 {
        return switch (link) {
            .made => |named| named,
            .attached => |attached| attached.target,
            .none, .asked => null,
        };
    }

    /// The session, where the page is attached.
    pub fn session(link: Link) ?[]const u8 {
        return switch (link) {
            .attached => |attached| attached.session,
            .none, .asked, .made => null,
        };
    }
};

/// A dialog a page shows — an alert, a confirm, a prompt, or one asking to leave — which holds its scripts until it is
/// answered: its kind, its message, and the text a prompt offers.
pub const Dialog = struct { kind: []const u8, message: []const u8, offered: []const u8 };

/// A message of a page's console, or an error its script threw: its level, its text, and its number among the page's,
/// from 1.
pub const Message = struct { level: Level, text: []const u8, number: u64 };

/// How much a message of a console matters, as the console's own calls name it.
pub const Level = enum {
    debug,
    log,
    info,
    warning,
    @"error",

    /// The level of a console's call of `kind` — `console.error`'s, `console.assert`'s — the rest logged.
    pub fn of(kind: []const u8) Level {
        if (std.mem.eql(u8, kind, "error") or std.mem.eql(u8, kind, "assert")) return .@"error";
        if (std.mem.eql(u8, kind, "warning")) return .warning;
        if (std.mem.eql(u8, kind, "info")) return .info;
        if (std.mem.eql(u8, kind, "debug")) return .debug;
        return .log;
    }
};

/// How many messages a page keeps, and how many bytes of each.
pub const messages_max = 50;
pub const message_bytes_max = 2000;

/// What waits for a page to load: the document it awaits, and what is told as it loaded, or as the page went, why.
pub const Awaiting = struct {
    context: *anyopaque,
    awaited: Awaited,
    told: *const fn (context: *anyopaque, outcome: Loaded) void,
};

/// The document awaited: one by the id of the load that makes it; or the first loaded other than one — none, any.
pub const Awaited = union(enum) { document: []const u8, other_than: ?[]const u8 };

/// How a wait for a page to load ended: it loaded, or the page went, for the reason given.
pub const Loaded = union(enum) { loaded, gone: []const u8 };

/// Whether it has an entry to go back to, and one to go forward to.
pub fn canGoBack(page: *const Page) bool {
    return page.at > 0;
}

pub fn canGoForward(page: *const Page) bool {
    return page.at + 1 < page.history.len;
}

/// Lets go of what it holds, what waits for it told it went for `reason`.
pub fn deinit(page: *Page, allocator: Allocator, reason: []const u8) void {
    page.gone(allocator, reason);
    page.awaiting.deinit(allocator);
    page.unlink(allocator);
    page.forget(allocator);
    for (page.messages.items) |message| allocator.free(message.text);
    page.messages.deinit(allocator);
    if (page.going) |going| allocator.free(going);
    if (page.frame) |frame| allocator.free(frame.data);
    allocator.free(page.history);
    allocator.free(page.url);
    allocator.free(page.title);
    allocator.free(page.thread);
    allocator.free(page.id);
}

/// Lets go of the target it stood with, leaving it with none.
pub fn unlink(page: *Page, allocator: Allocator) void {
    switch (page.link) {
        .none, .asked => {},
        .made => |named| allocator.free(named),
        .attached => |attached| {
            allocator.free(attached.target);
            allocator.free(attached.session);
        },
    }
    page.link = .none;
}

/// Lets go of the document it showed, its snapshot and its dialog, as the target that showed them went.
pub fn forget(page: *Page, allocator: Allocator) void {
    if (page.document) |document| allocator.free(document);
    if (page.snapshot) |snapshot| allocator.free(snapshot);
    page.document = null;
    page.snapshot = null;
    page.loaded = false;
    page.closedDialog(allocator);
}

/// Tells what waits for it to load that it went, for `reason`.
pub fn gone(page: *Page, allocator: Allocator, reason: []const u8) void {
    var awaiting = page.awaiting;
    page.awaiting = .empty;
    defer awaiting.deinit(allocator);
    for (awaiting.items) |each| {
        freeAwaited(allocator, each.awaited);
        each.told(each.context, .{ .gone = reason });
    }
}

/// Shows the document made by the load `document`: loaded already where it came back from the back-forward cache.
pub fn navigated(page: *Page, allocator: Allocator, document: []const u8, restored: bool) !void {
    if (page.document == null or !std.mem.eql(u8, page.document.?, document)) {
        const copy = try allocator.dupe(u8, document);
        if (page.document) |before| allocator.free(before);
        page.document = copy;
        page.loaded = false;
    }
    if (restored) page.loaded = true;
    page.settle(allocator);
}

/// Takes a step of its main frame's life, as the browser names it: a document begun by the load `document`, or loaded.
pub fn lived(page: *Page, allocator: Allocator, step: []const u8, document: []const u8) !void {
    if (std.mem.eql(u8, step, "init")) return page.navigated(allocator, document, false);
    if (!std.mem.eql(u8, step, "load")) return;
    // A document the page began before its events were heard is told of first as it loads.
    if (page.document == null) try page.navigated(allocator, document, false);
    if (!std.mem.eql(u8, page.document.?, document)) return;
    page.loaded = true;
    page.settle(allocator);
}

/// Waits for it to load the document `awaiting` awaits: told at once where it did.
pub fn await(page: *Page, allocator: Allocator, awaiting: Awaiting) !void {
    if (page.shows(awaiting.awaited)) return awaiting.told(awaiting.context, .loaded);
    const kept: Awaiting = .{ .context = awaiting.context, .told = awaiting.told, .awaited = switch (awaiting.awaited) {
        .document => |document| .{ .document = try allocator.dupe(u8, document) },
        .other_than => |before| .{ .other_than = if (before) |each| try allocator.dupe(u8, each) else null },
    } };
    errdefer freeAwaited(allocator, kept.awaited);
    try page.awaiting.append(allocator, kept);
}

/// Whether it shows the document `awaited` loaded.
fn shows(page: *const Page, awaited: Awaited) bool {
    const document = page.document orelse return false;
    if (!page.loaded) return false;
    return switch (awaited) {
        .document => |wanted| std.mem.eql(u8, wanted, document),
        .other_than => |before| before == null or !std.mem.eql(u8, before.?, document),
    };
}

/// Tells what waits for the document it shows loaded that it loaded.
fn settle(page: *Page, allocator: Allocator) void {
    var index: usize = 0;
    while (index < page.awaiting.items.len) {
        const each = page.awaiting.items[index];
        if (!page.shows(each.awaited)) {
            index += 1;
            continue;
        }
        _ = page.awaiting.orderedRemove(index);
        freeAwaited(allocator, each.awaited);
        each.told(each.context, .loaded);
    }
}

fn freeAwaited(allocator: Allocator, awaited: Awaited) void {
    switch (awaited) {
        .document => |document| allocator.free(document),
        .other_than => |before| if (before) |each| allocator.free(each),
    }
}

/// Marks the document it shows as the one its snapshot was taken of.
pub fn tookSnapshot(page: *Page, allocator: Allocator) !void {
    const copy = if (page.document) |document| try allocator.dupe(u8, document) else null;
    if (page.snapshot) |before| allocator.free(before);
    page.snapshot = copy;
}

/// Shows the dialog `dialog`, copied.
pub fn openedDialog(page: *Page, allocator: Allocator, dialog: Dialog) !void {
    const kind = try allocator.dupe(u8, dialog.kind);
    errdefer allocator.free(kind);
    const message = try allocator.dupe(u8, dialog.message);
    errdefer allocator.free(message);
    const offered = try allocator.dupe(u8, dialog.offered);
    page.closedDialog(allocator);
    page.dialog = .{ .kind = kind, .message = message, .offered = offered };
}

pub fn closedDialog(page: *Page, allocator: Allocator) void {
    const dialog = page.dialog orelse return;
    allocator.free(dialog.kind);
    allocator.free(dialog.message);
    allocator.free(dialog.offered);
    page.dialog = null;
}

/// Keeps a message of its console's at `level`, its text cut past `message_bytes_max`; the oldest let go of past
/// `messages_max`.
pub fn heard(page: *Page, allocator: Allocator, level: Level, text: []const u8) !void {
    const kept = try allocator.dupe(u8, text[0..@min(text.len, message_bytes_max)]);
    errdefer allocator.free(kept);
    if (page.messages.items.len == messages_max) allocator.free(page.messages.orderedRemove(0).text);
    page.messages_told += 1;
    try page.messages.append(allocator, .{ .level = level, .text = kept, .number = page.messages_told });
}

test "what waits for a page is told as the document it awaits loads, or as the page goes" {
    const allocator = std.testing.allocator;
    const Told = struct {
        loaded: usize = 0,
        gone: usize = 0,
        fn told(context: *anyopaque, outcome: Loaded) void {
            const counted: *@This() = @ptrCast(@alignCast(context));
            switch (outcome) {
                .loaded => counted.loaded += 1,
                .gone => counted.gone += 1,
            }
        }
    };
    var told: Told = .{};
    var page: Page = .{ .id = try allocator.dupe(u8, "p"), .thread = try allocator.dupe(u8, "t"), .key = 1, .url = try allocator.dupe(u8, "about:blank"), .title = try allocator.dupe(u8, ""), .size = .{ .width = 1, .height = 1 } };
    defer page.deinit(allocator, "closed");

    // Its first document, loaded though its beginning was never heard.
    try page.await(allocator, .{ .context = &told, .awaited = .{ .other_than = null }, .told = Told.told });
    try page.lived(allocator, "load", "L1");
    try std.testing.expectEqual(@as(usize, 1), told.loaded);

    // A document by its load, and the next other than the first: neither told before it loads.
    try page.await(allocator, .{ .context = &told, .awaited = .{ .document = "L2" }, .told = Told.told });
    try page.await(allocator, .{ .context = &told, .awaited = .{ .other_than = "L1" }, .told = Told.told });
    try page.navigated(allocator, "L2", false);
    try std.testing.expectEqual(@as(usize, 1), told.loaded);
    try page.lived(allocator, "load", "L2");
    try std.testing.expectEqual(@as(usize, 3), told.loaded);

    // One come back from the back-forward cache is loaded as it is shown; what waits as the page goes is told so.
    try page.navigated(allocator, "L1", true);
    try page.await(allocator, .{ .context = &told, .awaited = .{ .document = "L1" }, .told = Told.told });
    try std.testing.expectEqual(@as(usize, 4), told.loaded);
    try page.await(allocator, .{ .context = &told, .awaited = .{ .document = "L3" }, .told = Told.told });
    page.gone(allocator, "closed");
    try std.testing.expectEqual(@as(usize, 1), told.gone);

    // Its console's newest messages are kept, each numbered.
    for (0..messages_max + 2) |_| try page.heard(allocator, .of("log"), "hello");
    try std.testing.expectEqual(@as(usize, messages_max), page.messages.items.len);
    try std.testing.expectEqual(@as(u64, messages_max + 2), page.messages.items[messages_max - 1].number);
    try std.testing.expectEqual(Level.@"error", Level.of("assert"));
}
