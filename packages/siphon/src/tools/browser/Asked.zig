//! What the browser tools ask of the browser, which the loop alone touches, as a system call asks a kernel: asked from
//! a tool's task and done on the loop — the state of a page and its thread's pages; a page opened, navigated, closed,
//! or its load awaited; a command of the DevTools protocol sent to it; its snapshot taken — what came of it completing
//! the task's wait, as JSON. What is asked, and what comes of it, live in the completion's arena, so a task that gives
//! up leaves the loop nothing it let go of.
const Asked = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const runtime_ = @import("../../runtime.zig");
const Runtime = runtime_.Runtime;
const Completion = runtime_.Completion;
const Waits = runtime_.Waits;
const Browser = @import("../../browser.zig");
const Page = Browser.Page;
const Cdp = Browser.Cdp;

completion: *Completion,
browser: *Browser,
thread: []const u8,
op: Op,
/// The page an `open` opened, by its id, once it did.
opened: ?[]const u8 = null,

/// What is asked: the state of the page `page` — none for the thread's newest — with the thread's pages; a page opened
/// at `url`, once loaded; a page navigated to `url`, once loaded; a page's load of a document other than `before`
/// awaited; a command sent to a page; a page's snapshot taken; a page closed.
pub const Op = union(enum) {
    state: ?[]const u8,
    open: []const u8,
    navigate: struct { page: []const u8, url: []const u8 },
    load: struct { page: []const u8, before: ?[]const u8 },
    command: struct { page: []const u8, method: []const u8, params: []const u8 },
    snapshot: ?[]const u8,
    close: []const u8,
};

/// The size a page an agent opens is laid out at, until a person's view of it lays it out at theirs.
const opened_size: Browser.Size = .{ .width = 1280, .height = 800 };

/// A page as an agent reads it: its id, where it is and what it is called; the size it is laid out at; whether it
/// loads; the document it shows, by the id of the load that made it, and whether it loaded; whether its snapshot is of
/// that document; the dialog that holds it; the messages of its console since the last snapshot.
pub const Shown = struct {
    id: []const u8,
    url: []const u8,
    title: []const u8,
    width: u32,
    height: u32,
    loading: bool,
    document: ?[]const u8 = null,
    loaded: bool,
    current: bool,
    dialog: ?Page.Dialog = null,
    messages: []const Page.Message = &.{},
};

/// A page of a thread's, as the agent's list of them shows it.
pub const Listed = struct { id: []const u8, url: []const u8, title: []const u8 };

/// The state an agent reads: the page it acts on, where the thread has one, and the thread's pages.
pub const State = struct { page: ?Shown = null, pages: []const Listed = &.{} };

/// What a snapshot gives: the page's state as it was taken, and its accessibility tree as the browser gave it.
pub const Snapshot = struct { state: State, tree: std.json.Value };

/// An ask the loop was given, which the task waits on, a while at a time, until it lets go of it.
pub const Pending = struct {
    completion: *Completion,

    /// What came of it, as JSON, in `arena`, where it came within `timeout_ms`: error.Failed with the words for why,
    /// as `failure` keeps them; error.TimedOut where it has not come yet, the ask still pending; error.Canceled as a
    /// stop comes.
    pub fn wait(pending: Pending, io: std.Io, timeout_ms: u32, arena: Allocator, failure: *[]const u8) ![]const u8 {
        switch (try pending.completion.wait(io, timeout_ms)) {
            .result => |result| return arena.dupe(u8, result),
            .failure => |why| {
                failure.* = try arena.dupe(u8, why);
                return error.Failed;
            },
        }
    }

    /// Lets go of it, what comes of it after left for the loop to let go of.
    pub fn release(pending: Pending) void {
        pending.completion.release();
    }
};

/// Gives the loop `op` to ask of the browser for the thread `thread`, from a tool's task that waits on `waits`.
pub fn start(runtime: *Runtime, browser: *Browser, waits: *Waits, thread: []const u8, op: Op) !Pending {
    const completion = try Completion.create(runtime.allocator, waits);
    const asked = made(completion, browser, thread, op) catch |err| {
        completion.discard();
        return err;
    };
    runtime.post(.{ .context = asked, .run = perform, .drop = dropped });
    return .{ .completion = completion };
}

/// Asks `op` of the browser for the thread `thread`, from a tool's task that waits on `waits`, at most `timeout_ms`,
/// as `Pending.wait` tells what came of it.
pub fn ask(runtime: *Runtime, browser: *Browser, waits: *Waits, arena: Allocator, thread: []const u8, op: Op, timeout_ms: u32, failure: *[]const u8) ![]const u8 {
    const pending = try start(runtime, browser, waits, thread, op);
    defer pending.release();
    return pending.wait(runtime.host.io, timeout_ms, arena, failure);
}

/// What is asked, in the completion's arena.
fn made(completion: *Completion, browser: *Browser, thread: []const u8, op: Op) !*Asked {
    const arena = completion.arena();
    const asked = try arena.create(Asked);
    asked.* = .{ .completion = completion, .browser = browser, .thread = try arena.dupe(u8, thread), .op = try copyOf(arena, op) };
    return asked;
}

/// `op`, its words copied into `arena`.
fn copyOf(arena: Allocator, op: Op) !Op {
    const copy = struct {
        fn text(into: Allocator, words: []const u8) ![]const u8 {
            return into.dupe(u8, words);
        }
        fn maybe(into: Allocator, words: ?[]const u8) !?[]const u8 {
            return if (words) |each| try into.dupe(u8, each) else null;
        }
    };
    return switch (op) {
        .state => |page| .{ .state = try copy.maybe(arena, page) },
        .open => |url| .{ .open = try copy.text(arena, url) },
        .navigate => |going| .{ .navigate = .{ .page = try copy.text(arena, going.page), .url = try copy.text(arena, going.url) } },
        .load => |awaited| .{ .load = .{ .page = try copy.text(arena, awaited.page), .before = try copy.maybe(arena, awaited.before) } },
        .command => |sent| .{ .command = .{ .page = try copy.text(arena, sent.page), .method = try copy.text(arena, sent.method), .params = try copy.text(arena, sent.params) } },
        .snapshot => |page| .{ .snapshot = try copy.maybe(arena, page) },
        .close => |page| .{ .close = try copy.text(arena, page) },
    };
}

/// Does what was asked, on the loop: done at once, or once the browser answered or the page loaded; failed in words.
fn perform(context: *anyopaque) void {
    const asked: *Asked = @ptrCast(@alignCast(context));
    asked.done() catch |err| asked.fail(wordsOf(err));
}

/// What a task gave up on before the loop did it is let go of, the runtime closing.
fn dropped(context: *anyopaque) void {
    const asked: *Asked = @ptrCast(@alignCast(context));
    asked.fail("the runtime closed");
}

fn done(asked: *Asked) !void {
    const browser = asked.browser;
    switch (asked.op) {
        .state => |id| {
            const page = browser.pageFor(asked.thread, id) catch |err| switch (err) {
                error.NoPage => null,
                else => return err,
            };
            return asked.completeWith(try asked.stateJson(page, false));
        },
        .open => |url| {
            const page = try browser.open(asked.thread, url, opened_size);
            asked.opened = try asked.completion.arena().dupe(u8, page.id);
            try page.await(browser.allocator, .{ .context = asked, .awaited = .{ .other_than = null }, .told = loaded });
        },
        .navigate => |going| {
            const page = try browser.pageFor(asked.thread, going.page);
            // A page whose browser ended is opened again there, as the person's navigating opens it.
            if (page.link == .none) {
                try browser.navigate(page, going.url);
                return page.await(browser.allocator, .{ .context = asked, .awaited = .{ .other_than = null }, .told = loaded });
            }
            const params = try foundation.json.encode(asked.completion.arena(), .{ .url = going.url });
            try browser.sendToPage(page, "Page.navigate", params, .{ .context = asked, .key = 0, .answered = navigated });
        },
        .load => |awaited| {
            const page = try browser.pageFor(asked.thread, awaited.page);
            try page.await(browser.allocator, .{ .context = asked, .awaited = .{ .other_than = awaited.before }, .told = loaded });
        },
        .command => |sent| {
            const page = try browser.pageFor(asked.thread, sent.page);
            try browser.sendToPage(page, sent.method, sent.params, .{ .context = asked, .key = 0, .answered = commanded });
        },
        .snapshot => |id| {
            const page = try browser.pageFor(asked.thread, id);
            try browser.sendToPage(page, "Accessibility.getFullAXTree", "{}", .{ .context = asked, .key = 0, .answered = snapped });
        },
        .close => |id| {
            try browser.close(try browser.pageFor(asked.thread, id));
            return asked.completeWith(try asked.stateJson(null, false));
        },
    }
}

/// The state an agent reads of `page` — none, the thread's newest — as JSON; the page's messages marked read where
/// `reading` says.
fn stateJson(asked: *Asked, page: ?*Page, reading: bool) ![]const u8 {
    return foundation.json.encode(asked.completion.arena(), try asked.stateOf(page, reading));
}

fn stateOf(asked: *Asked, page: ?*Page, reading: bool) !State {
    const arena = asked.completion.arena();
    var listed: std.ArrayList(Listed) = .empty;
    var newest: ?*Page = null;
    for (asked.browser.pages.values()) |each| {
        if (!std.mem.eql(u8, each.thread, asked.thread)) continue;
        newest = each;
        try listed.append(arena, .{ .id = each.id, .url = each.url, .title = each.title });
    }
    var state: State = .{ .pages = listed.items };
    if (page orelse newest) |shown| {
        var messages: std.ArrayList(Page.Message) = .empty;
        for (shown.messages.items) |message| if (message.number > shown.messages_read) try messages.append(arena, message);
        const current = shown.snapshot != null and shown.document != null and std.mem.eql(u8, shown.snapshot.?, shown.document.?);
        state.page = .{
            .id = shown.id,
            .url = shown.url,
            .title = shown.title,
            .width = shown.size.width,
            .height = shown.size.height,
            .loading = shown.loading,
            .document = shown.document,
            .loaded = shown.loaded,
            .current = current,
            .dialog = shown.dialog,
            .messages = messages.items,
        };
        if (reading) shown.messages_read = shown.messages_told;
    }
    return state;
}

/// Hears a page's load awaited: its history read again, for the title the browser has for it; or why it went.
fn loaded(context: *anyopaque, outcome: Page.Loaded) void {
    const asked: *Asked = @ptrCast(@alignCast(context));
    switch (outcome) {
        .gone => |reason| asked.fail(reason),
        .loaded => {
            const page = asked.loadedPage() catch |err| return asked.fail(wordsOf(err));
            asked.browser.sendToPage(page, "Page.getNavigationHistory", "{}", .{ .context = asked, .key = 0, .answered = synced }) catch |err| asked.fail(wordsOf(err));
        },
    }
}

/// The page whose load was awaited.
fn loadedPage(asked: *const Asked) !*Page {
    const id = switch (asked.op) {
        .navigate => |going| going.page,
        .load => |awaited| awaited.page,
        else => asked.opened,
    };
    return asked.browser.pageFor(asked.thread, id);
}

/// Hears a loaded page's history: kept, with its title, then the state of the page.
fn synced(context: *anyopaque, _: u64, answer: Cdp.Answer) void {
    const asked: *Asked = @ptrCast(@alignCast(context));
    const history = asked.resultOf(answer) orelse return;
    const page = asked.loadedPage() catch |err| return asked.fail(wordsOf(err));
    asked.browser.tookHistory(page, history) catch |err| return asked.fail(wordsOf(err));
    asked.completeWith(asked.stateJson(page, false) catch |err| return asked.fail(wordsOf(err)));
}

/// Hears the browser's answer to a navigation: one that failed told so, in the browser's words; one within its
/// document done; one to a document of its own awaited till it loads.
fn navigated(context: *anyopaque, _: u64, answer: Cdp.Answer) void {
    const asked: *Asked = @ptrCast(@alignCast(context));
    const result = asked.resultOf(answer) orelse return;
    if (Cdp.textOf(result, "errorText")) |why| return asked.fail(why);
    const page = asked.browser.pageFor(asked.thread, asked.op.navigate.page) catch |err| return asked.fail(wordsOf(err));
    const document = Cdp.textOf(result, "loaderId") orelse {
        return asked.completeWith(asked.stateJson(page, false) catch |err| return asked.fail(wordsOf(err)));
    };
    page.await(asked.browser.allocator, .{ .context = asked, .awaited = .{ .document = document }, .told = loaded }) catch |err| asked.fail(wordsOf(err));
}

/// Hears the browser's answer to a command: its result as JSON.
fn commanded(context: *anyopaque, _: u64, answer: Cdp.Answer) void {
    const asked: *Asked = @ptrCast(@alignCast(context));
    const result = asked.resultOf(answer) orelse return;
    asked.completeWith(foundation.json.encode(asked.completion.arena(), result) catch return asked.fail("no room for the answer"));
}

/// Hears the page's accessibility tree: the snapshot, the page's state as it was taken, the document it is of and the
/// messages it tells marked so.
fn snapped(context: *anyopaque, _: u64, answer: Cdp.Answer) void {
    const asked: *Asked = @ptrCast(@alignCast(context));
    const tree = asked.resultOf(answer) orelse return;
    const page = asked.browser.pageFor(asked.thread, asked.op.snapshot) catch |err| return asked.fail(wordsOf(err));
    page.tookSnapshot(asked.browser.allocator) catch return asked.fail("no room for the snapshot");
    const state = asked.stateOf(page, true) catch return asked.fail("no room for the snapshot");
    asked.completeWith(foundation.json.encode(asked.completion.arena(), Snapshot{ .state = state, .tree = tree }) catch return asked.fail("no room for the snapshot"));
}

/// The result of `answer`, where it has one; else the completion failed, in the browser's words.
fn resultOf(asked: *Asked, answer: Cdp.Answer) ?std.json.Value {
    switch (answer) {
        .result => |result| return result,
        .failure => |why| asked.fail(why),
        .ended => asked.fail("the browser ended"),
    }
    return null;
}

/// Completes the ask with `result`: the last the loop does with it.
fn completeWith(asked: *Asked, result: []const u8) void {
    asked.completion.complete(.{ .result = result });
}

fn fail(asked: *Asked, why: []const u8) void {
    asked.completion.complete(.{ .failure = why });
}

/// The words for why an ask failed on the loop.
fn wordsOf(err: anyerror) []const u8 {
    return switch (err) {
        error.NoSuchPage => "no page of this thread has that id",
        error.NoPage => "the thread has no page open: navigate to an address to open one",
        error.NotAttached => "the browser does not show the page yet: wait for it to load",
        error.NoBrowser => "no browser is on this machine",
        error.OutOfMemory => "no room for it",
        else => @errorName(err),
    };
}
