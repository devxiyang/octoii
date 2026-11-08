//! The browser of the threads, where the person and the model look at the pages a thread works on: one headless
//! Chromium of the machine's, started as a page is first opened and spoken to over its DevTools pipe as the loop pumps,
//! its profile kept in the folder the host gives, so what the person signed in to stays. Each page is a target of its
//! own, as a tab is, of one thread's: made held at its start and set up before it loads anything, as a debugger starts
//! a process suspended; navigated, gone back and forward, reloaded and closed; laid out at the size its views ask;
//! clicked, typed into and scrolled as the person does it; and painted by the browser as it changes, the newest frame
//! kept for those that look at it, as a VNC server keeps its framebuffer for each client to ask for. A page a page opens
//! — a link to a new window — is a page of the same thread, as a browser opens it in a tab; one that closes itself is
//! gone. The listener is told as a thread's pages come, change and go, and as a page is painted anew. The loop alone
//! touches it.
const Browser = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const beak = @import("beak.zig");
const h = beak.h;
const Runtime = @import("runtime.zig").Runtime;
const Machine = @import("machine.zig");
pub const Cdp = @import("browser/Cdp.zig");

const log = std.log.scoped(.siphon);

allocator: Allocator,
runtime: *Runtime,
/// The machine the browser runs on; the program it is, by its path, none where the host names none; the folder its
/// profile is kept in, none for one that lasts as long as it runs.
machine: Machine.Host,
program: ?[]const u8,
profile: ?[]const u8,
listener: ?Listener = null,
/// The browser, once a page was first opened: its command, and its DevTools pipe.
running: ?*Running = null,
/// The pages, by their ids, in the order they were opened.
pages: std.StringArrayHashMapUnmanaged(*Page) = .empty,
/// The key the next page is known by in what the browser answers.
next_key: u64 = 1,

/// What hears of the pages: a thread's came, changed or went; a page was painted anew.
pub const Listener = struct {
    context: *anyopaque,
    pagesChanged: *const fn (context: *anyopaque, thread: []const u8) void,
    painted: *const fn (context: *anyopaque, page: []const u8) void,
};

/// The browser as it runs: its command; its DevTools pipe; and the sessions of the targets it attached to, held at
/// their start, that its answer has not named yet, by their targets — each claimed by the page that asked for its
/// target as the answer comes. They last as long as it runs.
const Running = struct {
    command: h.beak_handle,
    cdp: Cdp,
    unclaimed: std.StringHashMapUnmanaged([]const u8) = .empty,
};

pub const Page = @import("browser/Page.zig");
pub const Size = Page.Size;

/// What a page waits on the browser's answer for: its target made; its history read, to tell of it, or to go back or
/// forward an entry of it as it stands.
const Step = enum(u8) { created, history, back, forward };

/// The kinds of target the browser attaches to as they are made: pages alone, never its workers or its own views.
const attached_kinds = [_]struct { type: ?[]const u8 = null, exclude: ?bool = null }{ .{ .type = "page" }, .{ .exclude = true } };

/// The JPEG quality frames are painted at.
const frame_quality = 70;

/// The world of its own a page's title is watched from, out of the page's reach, as a browser reads a tab's title from
/// its document; and the binding it tells the title through, whenever it changes and as a document comes back from
/// the back-forward cache, whose title is its own again though nothing in it changed.
const title_world = "octoii";
const title_binding = "__octoiiTitle";
const title_watch =
    \\(() => {
    \\  let told;
    \\  const tell = () => {
    \\    const title = document.title;
    \\    if (title !== told) {
    \\      told = title;
    \\      globalThis.__octoiiTitle(title);
    \\    }
    \\  };
    \\  new MutationObserver(tell).observe(document, { subtree: true, childList: true, characterData: true });
    \\  addEventListener("pageshow", (event) => {
    \\    if (!event.persisted) return;
    \\    told = undefined;
    \\    tell();
    \\  });
    \\  tell();
    \\})();
;

/// Closes the browser, as the host stops: what waits for it told it ended.
pub fn deinit(browser: *Browser) void {
    browser.stop();
    for (browser.pages.values()) |page| browser.free(page, "the browser closed");
    browser.pages.deinit(browser.allocator);
}

fn stop(browser: *Browser) void {
    const running = browser.running orelse return;
    browser.runtime.unwatch(running.command);
    // Its pipe closed, the browser ends; the machine's reaper hangs up on what is left of it.
    _ = h.beak_close(running.command);
    var unclaimed = running.unclaimed.iterator();
    while (unclaimed.next()) |each| {
        browser.allocator.free(each.key_ptr.*);
        browser.allocator.free(each.value_ptr.*);
    }
    running.unclaimed.deinit(browser.allocator);
    running.cdp.deinit();
    browser.allocator.destroy(running);
    browser.running = null;
}

/// Lets go of `page`, what waits for it told it went for `reason`.
fn free(browser: *Browser, page: *Page, reason: []const u8) void {
    page.deinit(browser.allocator, reason);
    browser.allocator.destroy(page);
}

/// The page of `id`.
pub fn pageOf(browser: *const Browser, id: []const u8) !*Page {
    return browser.pages.get(id) orelse error.NoSuchPage;
}

/// The page of `thread`'s an agent acts on: the page `id`, where it is the thread's; else the thread's newest.
pub fn pageFor(browser: *const Browser, thread: []const u8, id: ?[]const u8) !*Page {
    if (id) |wanted| {
        const page = browser.pages.get(wanted) orelse return error.NoSuchPage;
        return if (std.mem.eql(u8, page.thread, thread)) page else error.NoSuchPage;
    }
    var newest: ?*Page = null;
    for (browser.pages.values()) |page| {
        if (std.mem.eql(u8, page.thread, thread)) newest = page;
    }
    return newest orelse error.NoPage;
}

/// Sends `method` with `params`, a JSON object as it is written, to `page`'s target, its answer handed to `told`;
/// error.NotAttached where the browser shows the page in no target yet, or none now.
pub fn sendToPage(browser: *Browser, page: *const Page, method: []const u8, params: []const u8, told: Cdp.Answered) !void {
    const running = browser.running orelse return error.NotAttached;
    const session = page.link.session() orelse return error.NotAttached;
    try running.cdp.sendJson(session, method, params, told);
}

/// The browser, started where it is not running: the program the host names, headless, its DevTools on a pipe of
/// descriptors 3 and 4, its profile in the folder the host gives; told of its targets, and attaching to each page as it
/// is made, held at its start.
fn started(browser: *Browser) !*Running {
    if (browser.running) |running| return running;
    const program = browser.program orelse return error.NoBrowser;
    const machine = browser.machine.handle orelse return error.NoMachine;
    var arena_state: std.heap.ArenaAllocator = .init(browser.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ program, "--headless", "--remote-debugging-pipe", "--no-first-run", "--no-default-browser-check", "--hide-scrollbars", "--mute-audio", "--disable-background-timer-throttling", "--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding" });
    if (browser.profile) |folder| try argv.append(arena, try std.mem.concat(arena, u8, &.{ "--user-data-dir=", folder }));
    try argv.append(arena, "about:blank");
    const words = try beak.bytesAll(arena, argv.items);
    const channel: h.beak_channel = .{ .input = 3, .output = 4 };
    var spawn = std.mem.zeroes(h.beak_spawn);
    spawn.machine = machine;
    spawn.argv = words.ptr;
    spawn.argv_count = words.len;
    spawn.cwd = beak.bytes(browser.machine.home orelse Machine.root);
    spawn.mode = h.BEAK_SPAWN_COPROCESS;
    spawn.channel = &channel;
    var command: h.beak_handle = 0;
    try beak.check(h.beak_command_spawn(&spawn, &command));
    errdefer _ = h.beak_close(command);
    const running = try browser.allocator.create(Running);
    errdefer browser.allocator.destroy(running);
    running.* = .{ .command = command, .cdp = .{ .allocator = browser.allocator, .command = command, .listener = .{ .context = browser, .event = event } } };
    try browser.runtime.watch(command, .{ .context = browser, .event = heard });
    browser.running = running;
    try running.cdp.send(null, "Target.setDiscoverTargets", .{ .discover = true }, null);
    try running.cdp.send(null, "Target.setAutoAttach", .{ .autoAttach = true, .waitForDebuggerOnStart = true, .flatten = true, .filter = &attached_kinds }, null);
    return running;
}

/// Hears the browser's command as the loop pumps: what it wrote to its pipe, taken; its end, which leaves every page
/// without its target.
fn heard(context: *anyopaque, told: *const h.beak_event) void {
    const browser: *Browser = @ptrCast(@alignCast(context));
    const running = browser.running orelse return;
    switch (told.type) {
        h.BEAK_EVENT_OUTPUT => running.cdp.take(beak.slice(told.bytes)),
        h.BEAK_EVENT_EXIT => {
            log.warn("the browser ended", .{});
            browser.stop();
            for (browser.pages.values()) |page| browser.detach(page);
        },
        else => {},
    }
}

/// Leaves `page` without the target it had, as the browser that made it ended: a page opened again as it is navigated
/// or reloaded, painted again where it is followed.
fn detach(browser: *Browser, page: *Page) void {
    page.unlink(browser.allocator);
    page.forget(browser.allocator);
    page.gone(browser.allocator, "the browser ended");
    page.loading = false;
    browser.tellPages(page.thread);
}

fn tellPages(browser: *Browser, thread: []const u8) void {
    if (browser.listener) |listener| listener.pagesChanged(listener.context, thread);
}

/// A page opened for `thread`, laid out at `size`: at `url`, or about:blank.
pub fn open(browser: *Browser, thread: []const u8, url: ?[]const u8, size: Size) !*Page {
    _ = try browser.started();
    const page = try browser.made(thread, url orelse "about:blank", size);
    errdefer browser.remove(page, "it could not be made");
    try browser.create(page);
    browser.tellPages(thread);
    return page;
}

/// A page of `thread`'s at `url`, laid out at `size`, with no target yet.
fn made(browser: *Browser, thread: []const u8, url: []const u8, size: Size) !*Page {
    const allocator = browser.allocator;
    const page = try allocator.create(Page);
    errdefer allocator.destroy(page);
    const minted = try browser.runtime.volume.mint(browser.runtime.now());
    const id = try allocator.dupe(u8, &minted);
    errdefer allocator.free(id);
    const owner = try allocator.dupe(u8, thread);
    errdefer allocator.free(owner);
    const at = try allocator.dupe(u8, url);
    errdefer allocator.free(at);
    page.* = .{ .id = id, .thread = owner, .key = browser.next_key, .url = at, .size = size };
    browser.next_key += 1;
    try browser.pages.put(allocator, id, page);
    return page;
}

/// Asks the browser for a target for `page`, at its address, attached to as it is made.
fn create(browser: *Browser, page: *Page) !void {
    const running = try browser.started();
    try running.cdp.send(null, "Target.createTarget", .{ .url = page.url }, browser.waiter(page, .created));
    page.link = .asked;
}

/// Takes `page` out of its thread, what waits for it told it went for `reason`.
fn remove(browser: *Browser, page: *Page, reason: []const u8) void {
    _ = browser.pages.orderedRemove(page.id);
    browser.tellPages(page.thread);
    browser.free(page, reason);
}

fn waiter(browser: *Browser, page: *const Page, step: Step) Cdp.Answered {
    return .{ .context = browser, .key = page.key << 8 | @backingInt(step), .answered = answered };
}

/// Takes the browser's answer for a page's step: its target made; its history read. A page's target the browser
/// could not make leaves it with none; one made for a page gone is closed; a step the browser ended before answering
/// is let go of.
fn answered(context: *anyopaque, asked: u64, answer: Cdp.Answer) void {
    const browser: *Browser = @ptrCast(@alignCast(context));
    const step: Step = @fromBackingInt(@intCast(@as(u8, @truncate(asked))));
    // A step the browser ended before it answered is let go of, its page detached as the browser ends.
    if (answer == .ended) return;
    const page = browser.pageByKey(asked >> 8);
    const result = switch (answer) {
        .result => |result| result,
        .ended => unreachable,
        .failure => |why| {
            if (page) |failed| if (step == .created and failed.link == .asked) {
                failed.link = .none;
            };
            return log.warn("the browser refused a page's step: {s}", .{why});
        },
    };
    const outcome = if (page) |own| browser.took(own, step, result) else browser.orphaned(step, result);
    outcome catch |err| log.warn("a page's step failed: {s}", .{@errorName(err)});
}

/// Closes the target made for a page gone before it was.
fn orphaned(browser: *Browser, step: Step, result: std.json.Value) !void {
    if (step != .created) return;
    const running = browser.running orelse return;
    const target = Cdp.textOf(result, "targetId") orelse return;
    try running.cdp.send(null, "Target.closeTarget", .{ .targetId = target }, null);
}

fn took(browser: *Browser, page: *Page, step: Step, result: std.json.Value) !void {
    switch (step) {
        .created => {
            if (page.link != .asked) return;
            const running = browser.running orelse return;
            const target = Cdp.textOf(result, "targetId") orelse return error.NoTarget;
            if (running.unclaimed.fetchRemove(target)) |claimed| {
                defer browser.allocator.free(claimed.key);
                defer browser.allocator.free(claimed.value);
                return browser.attach(page, claimed.key, claimed.value);
            }
            page.link = .{ .made = try browser.allocator.dupe(u8, target) };
        },
        .history => try browser.tookHistory(page, result),
        .back => {
            try browser.tookHistory(page, result);
            if (page.canGoBack()) try browser.toEntry(page, page.at - 1);
        },
        .forward => {
            try browser.tookHistory(page, result);
            if (page.canGoForward()) try browser.toEntry(page, page.at + 1);
        },
    }
}

/// Keeps `page`'s history as the browser read it, and the title the browser has for the entry it stands at, and tells
/// of them.
pub fn tookHistory(browser: *Browser, page: *Page, result: std.json.Value) !void {
    const entries = (Cdp.memberOf(result, "entries") orelse return).array.items;
    const ids = try browser.allocator.alloc(i64, entries.len);
    for (entries, ids) |entry, *each| each.* = @intFromFloat(Cdp.numberOf(entry, "id") orelse 0);
    browser.allocator.free(page.history);
    page.history = ids;
    page.at = @intFromFloat(Cdp.numberOf(result, "currentIndex") orelse 0);
    // The browser's own record of the document's title, as its tab shows it: the watch's news of it comes by another
    // way, and may come after the page loaded.
    if (page.at < entries.len) {
        const title = Cdp.textOf(entries[page.at], "title") orelse "";
        if (title.len > 0) try replace(browser.allocator, &page.title, title);
    }
    browser.tellPages(page.thread);
}

/// Takes `page` to the entry at `index` of its history.
fn toEntry(browser: *Browser, page: *const Page, index: usize) !void {
    try browser.toPage(page, "Page.navigateToHistoryEntry", .{ .entryId = page.history[index] });
}

/// Hears the browser attach to a target it made, held at its start: the page that asked for it attached to it, where
/// the browser's answer named it; a page a page of a thread's opened made a page of the thread; and else kept for the
/// page whose answer will name it. A target that was there before is none of the threads', and let go.
fn heardAttached(browser: *Browser, params: std.json.Value) !void {
    const running = browser.running orelse return;
    const session = Cdp.textOf(params, "sessionId") orelse return;
    const info = Cdp.memberOf(params, "targetInfo") orelse return;
    const target = Cdp.textOf(info, "targetId") orelse return;
    const held = Cdp.memberOf(params, "waitingForDebugger") orelse .null;
    if (held != .bool or !held.bool) return running.cdp.send(null, "Target.detachFromTarget", .{ .sessionId = session }, null);
    if (browser.pageByTarget(target)) |page| return browser.attach(page, target, session);
    if (Cdp.textOf(info, "openerId")) |opener| if (browser.pageByTarget(opener)) |from| {
        const url = Cdp.textOf(info, "url") orelse "";
        const page = try browser.made(from.thread, if (url.len == 0) "about:blank" else url, from.size);
        try browser.attach(page, target, session);
        return browser.tellPages(page.thread);
    };
    const kept_target = try browser.allocator.dupe(u8, target);
    errdefer browser.allocator.free(kept_target);
    const kept_session = try browser.allocator.dupe(u8, session);
    errdefer browser.allocator.free(kept_session);
    try running.unclaimed.put(browser.allocator, kept_target, kept_session);
}

/// Attaches `page` to `target` by `session`: its events and its main frame's life heard, its title watched, laid out at its size and painted
/// where it is to be; then let run, its history read — its first navigation may have been made before its events
/// were heard — and taken where it was to go.
fn attach(browser: *Browser, page: *Page, target: []const u8, session: []const u8) !void {
    const running = browser.running orelse return;
    const own_target = try browser.allocator.dupe(u8, target);
    errdefer browser.allocator.free(own_target);
    const own_session = try browser.allocator.dupe(u8, session);
    page.unlink(browser.allocator);
    page.link = .{ .attached = .{ .target = own_target, .session = own_session } };
    try running.cdp.send(own_session, "Page.enable", Cdp.none, null);
    try running.cdp.send(own_session, "Page.setLifecycleEventsEnabled", .{ .enabled = true }, null);
    try running.cdp.send(own_session, "Runtime.enable", Cdp.none, null);
    try running.cdp.send(own_session, "Runtime.addBinding", .{ .name = title_binding, .executionContextName = title_world }, null);
    try running.cdp.send(own_session, "Page.addScriptToEvaluateOnNewDocument", .{ .source = title_watch, .worldName = title_world, .runImmediately = true }, null);
    try browser.layOut(page);
    if (page.casting) try browser.startCasting(page);
    try running.cdp.send(own_session, "Runtime.runIfWaitingForDebugger", Cdp.none, null);
    try running.cdp.send(own_session, "Page.getNavigationHistory", Cdp.none, browser.waiter(page, .history));
    if (page.going) |going| {
        defer browser.allocator.free(going);
        page.going = null;
        try browser.toPage(page, "Page.navigate", .{ .url = going });
    }
}

fn pageByKey(browser: *const Browser, wanted: u64) ?*Page {
    for (browser.pages.values()) |page| if (page.key == wanted) return page;
    return null;
}

fn pageBySession(browser: *const Browser, session: []const u8) ?*Page {
    for (browser.pages.values()) |page| if (page.link.session()) |own| if (std.mem.eql(u8, own, session)) return page;
    return null;
}

fn pageByTarget(browser: *const Browser, target: []const u8) ?*Page {
    for (browser.pages.values()) |page| if (page.link.target()) |own| if (std.mem.eql(u8, own, target)) return page;
    return null;
}

/// Hears an event of the browser's: a target attached to, its address changed, or the target gone — a page that
/// closed itself gone from its thread; of a page's session, its title as the page's own watch tells it, its loading,
/// its navigation, a frame painted.
fn event(context: *anyopaque, session: ?[]const u8, method: []const u8, params: std.json.Value) void {
    const browser: *Browser = @ptrCast(@alignCast(context));
    browser.heardEvent(session, method, params) catch |err| log.warn("the browser's {s} was not taken: {s}", .{ method, @errorName(err) });
}

fn heardEvent(browser: *Browser, session: ?[]const u8, method: []const u8, params: std.json.Value) !void {
    const own = session orelse return browser.heardOwn(method, params);
    const page = browser.pageBySession(own) orelse return;
    if (std.mem.eql(u8, method, "Page.screencastFrame")) return browser.painted(page, params);
    if (std.mem.eql(u8, method, "Runtime.bindingCalled")) {
        if (!std.mem.eql(u8, Cdp.textOf(params, "name") orelse return, title_binding)) return;
        try replace(browser.allocator, &page.title, Cdp.textOf(params, "payload") orelse return);
        return browser.tellPages(page.thread);
    }
    if (std.mem.startsWith(u8, method, "Page.frame") or std.mem.eql(u8, method, "Page.lifecycleEvent") or std.mem.eql(u8, method, "Page.navigatedWithinDocument")) return browser.heardNavigation(page, own, method, params);
    return browser.heardScripts(page, method, params);
}

/// Hears of `page`'s frames: its main frame's loading begun and ended, the documents it shows and each step of their
/// life; a frame navigated, or the document loaded, its history read again.
fn heardNavigation(browser: *Browser, page: *Page, session: []const u8, method: []const u8, params: std.json.Value) !void {
    const main = page.link.target() orelse return;
    if (std.mem.eql(u8, method, "Page.lifecycleEvent")) {
        if (!std.mem.eql(u8, Cdp.textOf(params, "frameId") orelse return, main)) return;
        const step = Cdp.textOf(params, "name") orelse return;
        try page.lived(browser.allocator, step, Cdp.textOf(params, "loaderId") orelse return);
        // Loaded, the document has the title it was written with: its history is read again for it.
        if (!std.mem.eql(u8, step, "load")) return;
    } else if (std.mem.eql(u8, method, "Page.frameStartedLoading") or std.mem.eql(u8, method, "Page.frameStoppedLoading")) {
        if (!std.mem.eql(u8, Cdp.textOf(params, "frameId") orelse return, main)) return;
        page.loading = std.mem.eql(u8, method, "Page.frameStartedLoading");
        return browser.tellPages(page.thread);
    } else if (std.mem.eql(u8, method, "Page.frameNavigated")) {
        const frame = Cdp.memberOf(params, "frame") orelse return;
        if (Cdp.memberOf(frame, "parentId") == null) {
            const restored = std.mem.eql(u8, Cdp.textOf(params, "type") orelse "", "BackForwardCacheRestore");
            try page.navigated(browser.allocator, Cdp.textOf(frame, "loaderId") orelse return, restored);
        }
    } else if (!std.mem.eql(u8, method, "Page.navigatedWithinDocument")) return;
    const running = browser.running orelse return;
    try running.cdp.send(session, "Page.getNavigationHistory", Cdp.none, browser.waiter(page, .history));
}

/// Hears what `page`'s scripts do: a dialog opened and answered, told of as the page is; a message of its console, an
/// error one threw, kept for an agent to read.
fn heardScripts(browser: *Browser, page: *Page, method: []const u8, params: std.json.Value) !void {
    if (std.mem.eql(u8, method, "Page.javascriptDialogOpening")) {
        try page.openedDialog(browser.allocator, .{
            .kind = Cdp.textOf(params, "type") orelse "alert",
            .message = Cdp.textOf(params, "message") orelse "",
            .offered = Cdp.textOf(params, "defaultPrompt") orelse "",
        });
        return browser.tellPages(page.thread);
    }
    if (std.mem.eql(u8, method, "Page.javascriptDialogClosed")) {
        page.closedDialog(browser.allocator);
        return browser.tellPages(page.thread);
    }
    if (std.mem.eql(u8, method, "Runtime.consoleAPICalled")) {
        var arena_state: std.heap.ArenaAllocator = .init(browser.allocator);
        defer arena_state.deinit();
        return page.heard(browser.allocator, .of(Cdp.textOf(params, "type") orelse "log"), try wordsOf(arena_state.allocator(), params));
    }
    if (std.mem.eql(u8, method, "Runtime.exceptionThrown")) {
        const details = Cdp.memberOf(params, "exceptionDetails") orelse return;
        const thrown = if (Cdp.memberOf(details, "exception")) |exception| Cdp.textOf(exception, "description") else null;
        return page.heard(browser.allocator, .@"error", thrown orelse Cdp.textOf(details, "text") orelse "an error was thrown");
    }
}

/// The words of a console's call: each of what it was given, a string as it is, a number or a truth as JSON writes
/// it, anything else by the browser's description of it, a space between each.
fn wordsOf(arena: Allocator, params: std.json.Value) ![]const u8 {
    const given = Cdp.memberOf(params, "args") orelse return "";
    if (given != .array) return "";
    var words: std.ArrayList(u8) = .empty;
    for (given.array.items, 0..) |each, index| {
        if (index > 0) try words.append(arena, ' ');
        const value = Cdp.memberOf(each, "value");
        if (value != null and value.? == .string) {
            try words.appendSlice(arena, value.?.string);
        } else if (value != null and value.? != .null) {
            try words.appendSlice(arena, try foundation.json.encode(arena, value.?));
        } else {
            try words.appendSlice(arena, Cdp.textOf(each, "description") orelse Cdp.textOf(each, "type") orelse "");
        }
    }
    return words.items;
}

/// Hears an event of the browser's own, of no page's session.
fn heardOwn(browser: *Browser, method: []const u8, params: std.json.Value) !void {
    if (std.mem.eql(u8, method, "Target.attachedToTarget")) return browser.heardAttached(params);
    if (std.mem.eql(u8, method, "Target.targetInfoChanged")) {
        const info = Cdp.memberOf(params, "targetInfo") orelse return;
        const page = browser.pageByTarget(Cdp.textOf(info, "targetId") orelse return) orelse return;
        try replace(browser.allocator, &page.url, Cdp.textOf(info, "url") orelse page.url);
        return browser.tellPages(page.thread);
    }
    if (std.mem.eql(u8, method, "Target.targetDestroyed")) {
        const target = Cdp.textOf(params, "targetId") orelse return;
        if (browser.pageByTarget(target)) |page| return browser.remove(page, "it closed itself");
        const running = browser.running orelse return;
        if (running.unclaimed.fetchRemove(target)) |gone| {
            browser.allocator.free(gone.key);
            browser.allocator.free(gone.value);
        }
    }
}

/// Keeps the frame the browser painted as the page's newest, and acknowledges it, so it paints the next.
fn painted(browser: *Browser, page: *Page, params: std.json.Value) !void {
    const running = browser.running orelse return;
    const data = Cdp.textOf(params, "data") orelse return;
    const metadata = Cdp.memberOf(params, "metadata") orelse return;
    const copy = try browser.allocator.dupe(u8, data);
    const number = if (page.frame) |frame| frame.number + 1 else 1;
    if (page.frame) |frame| browser.allocator.free(frame.data);
    page.frame = .{
        .data = copy,
        .width = @intFromFloat(Cdp.numberOf(metadata, "deviceWidth") orelse 0),
        .height = @intFromFloat(Cdp.numberOf(metadata, "deviceHeight") orelse 0),
        .number = number,
    };
    const acknowledged: i64 = @intFromFloat(Cdp.numberOf(params, "sessionId") orelse 0);
    try running.cdp.send(page.link.session(), "Page.screencastFrameAck", .{ .sessionId = acknowledged }, null);
    if (browser.listener) |listener| listener.painted(listener.context, page.id);
}

fn replace(allocator: Allocator, field: *[]const u8, value: []const u8) !void {
    if (field.ptr == value.ptr) return;
    const copy = try allocator.dupe(u8, value);
    allocator.free(field.*);
    field.* = copy;
}

/// Sends `method` with `params` to the page's target, where it is attached; else nothing.
fn toPage(browser: *Browser, page: *const Page, method: []const u8, params: anytype) !void {
    const running = browser.running orelse return;
    const session = page.link.session() orelse return;
    try running.cdp.send(session, method, params, null);
}

/// Takes `page` to `url`: once it is attached, where its target is being made; opened again there, where the browser
/// that held it ended.
pub fn navigate(browser: *Browser, page: *Page, url: []const u8) !void {
    switch (page.link) {
        .attached => try browser.toPage(page, "Page.navigate", .{ .url = url }),
        .asked, .made => {
            const going = try browser.allocator.dupe(u8, url);
            if (page.going) |before| browser.allocator.free(before);
            page.going = going;
        },
        .none => {
            try replace(browser.allocator, &page.url, url);
            try browser.create(page);
            browser.tellPages(page.thread);
        },
    }
}

/// Takes `page` back an entry in its history, or forward one, where it has one as the browser reads it now — what
/// was told of it may be behind.
pub fn goBack(browser: *Browser, page: *Page) !void {
    const running = browser.running orelse return;
    const session = page.link.session() orelse return;
    try running.cdp.send(session, "Page.getNavigationHistory", Cdp.none, browser.waiter(page, .back));
}

pub fn goForward(browser: *Browser, page: *Page) !void {
    const running = browser.running orelse return;
    const session = page.link.session() orelse return;
    try running.cdp.send(session, "Page.getNavigationHistory", Cdp.none, browser.waiter(page, .forward));
}

/// Answers the dialog that holds `page`: accepted — a prompt with `answer` — or dismissed.
pub fn answerDialog(browser: *Browser, page: *const Page, accept: bool, answer: ?[]const u8) !void {
    try browser.toPage(page, "Page.handleJavaScriptDialog", .{ .accept = accept, .promptText = answer });
}

/// Loads `page` again, its cache passed over where `bypass_cache` says; opened again where it is, where the browser
/// that held it ended.
pub fn reload(browser: *Browser, page: *Page, bypass_cache: bool) !void {
    switch (page.link) {
        .attached => try browser.toPage(page, "Page.reload", .{ .ignoreCache = bypass_cache }),
        .none => {
            try browser.create(page);
            browser.tellPages(page.thread);
        },
        .asked, .made => {},
    }
}

/// Closes every page of the thread `thread`, as the thread goes.
pub fn closeThread(browser: *Browser, thread: []const u8) void {
    var index = browser.pages.count();
    while (index > 0) {
        index -= 1;
        const page = browser.pages.values()[index];
        if (!std.mem.eql(u8, page.thread, thread)) continue;
        browser.close(page) catch |err| log.warn("a page of a thread gone was not closed: {s}", .{@errorName(err)});
    }
}

/// Closes `page`: its target closed, and the page gone from its thread.
pub fn close(browser: *Browser, page: *Page) !void {
    if (browser.running) |running| if (page.link.target()) |target| try running.cdp.send(null, "Target.closeTarget", .{ .targetId = target }, null);
    browser.remove(page, "it was closed");
}

/// Lays `page` out at `size`, painted at it where the browser paints it: its painting begun again, as a page laid out
/// anew where nothing in it moves is not painted again, and painting begun paints it at once.
pub fn resize(browser: *Browser, page: *Page, size: Size) !void {
    if (std.meta.eql(page.size, size)) return;
    page.size = size;
    try browser.layOut(page);
    if (!page.casting) return;
    try browser.toPage(page, "Page.stopScreencast", Cdp.none);
    try browser.startCasting(page);
}

fn layOut(browser: *Browser, page: *const Page) !void {
    const metrics = .{ .width = page.size.width, .height = page.size.height, .deviceScaleFactor = page.size.scale, .mobile = false };
    try browser.toPage(page, "Emulation.setDeviceMetricsOverride", metrics);
}

/// Has the browser paint `page` as it changes, or no more.
pub fn cast(browser: *Browser, page: *Page, painting: bool) !void {
    if (page.casting == painting) return;
    page.casting = painting;
    if (painting) return browser.startCasting(page);
    try browser.toPage(page, "Page.stopScreencast", Cdp.none);
}

fn startCasting(browser: *Browser, page: *const Page) !void {
    const scale = @max(page.size.scale, 1);
    const width: u32 = @intFromFloat(@as(f32, @floatFromInt(page.size.width)) * scale);
    const height: u32 = @intFromFloat(@as(f32, @floatFromInt(page.size.height)) * scale);
    try browser.toPage(page, "Page.startScreencast", .{ .format = "jpeg", .quality = frame_quality, .maxWidth = width, .maxHeight = height, .everyNthFrame = 1 });
}

/// A mouse's press, release, move or turn of its wheel over `page`, at `x`, `y` in its CSS pixels: the button pressed
/// or let go, and the buttons held, as the DOM counts them — left 1, right 2, middle 4 — so a move with one held drags.
pub const Mouse = struct {
    type: enum { down, up, move, wheel },
    x: f64,
    y: f64,
    button: enum { none, left, middle, right } = .none,
    buttons: u32 = 0,
    clicks: u32 = 0,
    modifiers: u32 = 0,
    delta_x: f64 = 0,
    delta_y: f64 = 0,
};

pub fn mouse(browser: *Browser, page: *const Page, given: Mouse) !void {
    const kind = switch (given.type) {
        .down => "mousePressed",
        .up => "mouseReleased",
        .move => "mouseMoved",
        .wheel => "mouseWheel",
    };
    try browser.toPage(page, "Input.dispatchMouseEvent", .{
        .type = kind,
        .x = given.x,
        .y = given.y,
        .button = @tagName(given.button),
        .buttons = given.buttons,
        .clickCount = given.clicks,
        .modifiers = given.modifiers,
        .deltaX = given.delta_x,
        .deltaY = given.delta_y,
    });
}

/// A key pressed or let go on `page`: its name and the key it is on, as the DOM names them, the text it types, the
/// modifiers held, its virtual key code, and the editing commands it stands for — `selectAll`, `undo` — as the person's
/// platform binds its shortcuts, which a headless browser binds none of.
pub const Key = struct {
    type: enum { down, up },
    key: []const u8,
    code: []const u8,
    text: ?[]const u8 = null,
    modifiers: u32 = 0,
    key_code: u32 = 0,
    commands: []const []const u8 = &.{},
};

pub fn key(browser: *Browser, page: *const Page, given: Key) !void {
    const kind = switch (given.type) {
        .down => if (given.text != null) "keyDown" else "rawKeyDown",
        .up => "keyUp",
    };
    try browser.toPage(page, "Input.dispatchKeyEvent", .{
        .type = kind,
        .key = given.key,
        .code = given.code,
        .text = given.text,
        .modifiers = given.modifiers,
        .windowsVirtualKeyCode = given.key_code,
        .commands = given.commands,
    });
}

/// Text put into `page` where its focus is, as a paste or an input method puts it.
pub fn text(browser: *Browser, page: *const Page, typed: []const u8) !void {
    try browser.toPage(page, "Input.insertText", .{ .text = typed });
}
