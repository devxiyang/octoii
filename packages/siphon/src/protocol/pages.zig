//! The pages of the threads' browser as clients see them: a page opened for a thread, navigated, taken back and
//! forward, reloaded and closed, the dialog that holds it answered; followed in a view of its own size, the page laid
//! out at the smallest of its views, drawn at the finest, and painted while any view follows it; each follower sent the
//! newest frame the browser painted as its outbox has room, those it had no room for passed over, as a VNC server sends
//! a client the framebuffer it asks for; clicked, typed into and scrolled as the person does it. The clients that follow a thread are told of its
//! pages as they come, change and go.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const Browser = @import("../browser.zig");
const Connection = @import("Connection.zig");
const Clients = @import("Clients.zig");

/// A view's size: CSS pixels across and down, at least one of each, and how many device pixels it draws each with.
fn sizeOf(width: u32, height: u32, scale: f32) !Browser.Size {
    if (width == 0 or height == 0) return error.EmptyView;
    return .{ .width = width, .height = height, .scale = std.math.clamp(scale, 1, 4) };
}

/// A page opened for a thread, at the size of the view that opens it: about:blank, or `url`; its id.
pub fn open(connection: *Connection, arena: Allocator, id: []const u8, given: struct { thread: []const u8, url: ?[]const u8 = null, width: u32, height: u32, scale: f32 = 1 }) !void {
    const page = try connection.clients.browser.open(given.thread, given.url, try sizeOf(given.width, given.height, given.scale));
    return connection.answer(arena, id, .{ .page = page.id });
}

pub fn navigate(connection: *Connection, arena: Allocator, id: []const u8, given: struct { page: []const u8, url: []const u8 }) !void {
    const browser = connection.clients.browser;
    try browser.navigate(try browser.pageOf(given.page), given.url);
    return connection.answer(arena, id, Connection.nothing);
}

pub fn back(connection: *Connection, arena: Allocator, id: []const u8, given: struct { page: []const u8 }) !void {
    const browser = connection.clients.browser;
    try browser.goBack(try browser.pageOf(given.page));
    return connection.answer(arena, id, Connection.nothing);
}

pub fn forward(connection: *Connection, arena: Allocator, id: []const u8, given: struct { page: []const u8 }) !void {
    const browser = connection.clients.browser;
    try browser.goForward(try browser.pageOf(given.page));
    return connection.answer(arena, id, Connection.nothing);
}

/// A page loaded again, its cache passed over where `bypass_cache` says.
pub fn reload(connection: *Connection, arena: Allocator, id: []const u8, given: struct { page: []const u8, bypass_cache: bool = false }) !void {
    const browser = connection.clients.browser;
    try browser.reload(try browser.pageOf(given.page), given.bypass_cache);
    return connection.answer(arena, id, Connection.nothing);
}

/// The dialog that holds a page answered: accepted — a prompt with `text` — or dismissed.
pub fn dialog(connection: *Connection, arena: Allocator, id: []const u8, given: struct { page: []const u8, accept: bool, text: ?[]const u8 = null }) !void {
    const browser = connection.clients.browser;
    try browser.answerDialog(try browser.pageOf(given.page), given.accept, given.text);
    return connection.answer(arena, id, Connection.nothing);
}

/// A page closed: gone from its thread.
pub fn close(connection: *Connection, arena: Allocator, id: []const u8, given: struct { page: []const u8 }) !void {
    const browser = connection.clients.browser;
    try browser.close(try browser.pageOf(given.page));
    return connection.answer(arena, id, Connection.nothing);
}

/// A page followed in a view `width` by `height`, its newest frame sent first, then each it paints; the page laid out
/// at its views again.
pub fn follow(connection: *Connection, arena: Allocator, id: []const u8, given: struct { page: []const u8, width: u32, height: u32, scale: f32 = 1 }) !void {
    const clients = connection.clients;
    _ = try clients.browser.pageOf(given.page);
    try connection.following.followPage(given.page, try sizeOf(given.width, given.height, given.scale));
    try fit(clients, given.page);
    return connection.answer(arena, id, Connection.nothing);
}

/// A page the client follows shown in a view of another size; the page laid out at its views again.
pub fn resize(connection: *Connection, arena: Allocator, id: []const u8, given: struct { page: []const u8, width: u32, height: u32, scale: f32 = 1 }) !void {
    try connection.following.resizePage(given.page, try sizeOf(given.width, given.height, given.scale));
    try fit(connection.clients, given.page);
    return connection.answer(arena, id, Connection.nothing);
}

/// A page no longer followed; laid out at the views left, and painted no more where none is.
pub fn unfollow(connection: *Connection, arena: Allocator, id: []const u8, given: struct { page: []const u8 }) !void {
    connection.following.unfollowPage(given.page);
    try fit(connection.clients, given.page);
    return connection.answer(arena, id, Connection.nothing);
}

/// Lays the page `id`, where there is one, out at the views the clients following it show it in, and has the browser
/// paint it while one does; one no client shows keeps its size.
pub fn fit(clients: *Clients, id: []const u8) !void {
    const browser = clients.browser;
    const page = browser.pages.get(id) orelse return;
    const fitted = clients.fitted(Browser.Size, "pages", id);
    if (fitted) |size| try browser.resize(page, size);
    try browser.cast(page, fitted != null);
}

/// The mouse pressed, let go, moved or its wheel turned over a page, at a point of its CSS pixels.
pub fn mouse(connection: *Connection, arena: Allocator, id: []const u8, given: struct { page: []const u8, event: Browser.Mouse }) !void {
    const browser = connection.clients.browser;
    try browser.mouse(try browser.pageOf(given.page), given.event);
    return connection.answer(arena, id, Connection.nothing);
}

/// A key pressed or let go on a page.
pub fn key(connection: *Connection, arena: Allocator, id: []const u8, given: struct { page: []const u8, event: Browser.Key }) !void {
    const browser = connection.clients.browser;
    try browser.key(try browser.pageOf(given.page), given.event);
    return connection.answer(arena, id, Connection.nothing);
}

/// Text put into a page where its focus is, as pasted.
pub fn text(connection: *Connection, arena: Allocator, id: []const u8, given: struct { page: []const u8, text: []const u8 }) !void {
    const browser = connection.clients.browser;
    try browser.text(try browser.pageOf(given.page), given.text);
    return connection.answer(arena, id, Connection.nothing);
}

/// Where a client following a page stands: the size of its view, the number of the frame it was sent last, and whether
/// the page may have painted one it was not sent.
pub const Follow = struct { size: Browser.Size, sent: u64 = 0, changed: bool = true };

/// Sends a client following the page `id` its newest frame, where it was not sent it; marked unchanged then. A page
/// gone, or not painted yet, sends nothing.
pub fn send(browser: *const Browser, connection: *Connection, arena: Allocator, id: []const u8, follower: *Follow) !void {
    follower.changed = false;
    const page = browser.pages.get(id) orelse return;
    const frame = page.frame orelse return;
    if (frame.number <= follower.sent) return;
    connection.send(try foundation.json.encode(arena, .{ .event = "page-frame", .page = id, .frame = frame.number, .width = frame.width, .height = frame.height, .data = frame.data }));
    follower.sent = frame.number;
}

/// A page as a client following its thread is told of it: its id, where it is and what it is called, whether it loads,
/// whether it can go back and forward, and the dialog that holds it.
const Listed = struct { id: []const u8, url: []const u8, title: []const u8, loading: bool, back: bool, forward: bool, dialog: ?Browser.Page.Dialog };

/// The message that tells a client following the thread `thread` of its pages, in the order they were opened.
pub fn listEvent(browser: *const Browser, arena: Allocator, thread: []const u8) ![]const u8 {
    var listed: std.ArrayList(Listed) = .empty;
    for (browser.pages.values()) |page| {
        if (!std.mem.eql(u8, page.thread, thread)) continue;
        try listed.append(arena, .{ .id = page.id, .url = page.url, .title = page.title, .loading = page.loading, .back = page.canGoBack(), .forward = page.canGoForward(), .dialog = page.dialog });
    }
    return foundation.json.encode(arena, .{ .event = "pages", .thread = thread, .pages = listed.items });
}
