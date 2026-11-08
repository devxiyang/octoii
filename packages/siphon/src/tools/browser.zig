//! The browser tools: a thread's model looks at and acts on the thread's pages in the browser, as the person does in
//! the panel beside the chat — goes somewhere on them, reads them by their accessibility tree, clicks, types and presses
//! keys on them by the refs that tree gives, runs script in them, and waits for what it expects of them. Each asks the
//! browser, which the loop alone touches, for what it needs a step at a time, and tells what the browser gave as it
//! gave it, a failure in the browser's own words.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const typebox = @import("typebox");
const Tool = @import("Tool.zig");
const Table = @import("Table.zig");
const Browser = @import("../browser.zig");
const Asked = @import("browser/Asked.zig");
const snapshot = @import("browser/snapshot.zig");
const keys = @import("browser/keys.zig");

/// Adds the browser tools to `table`, each acting on `browser`.
pub fn register(table: *Table, browser: *Browser) !void {
    for (all) |tool| {
        var each = tool;
        each.context = browser;
        try table.add(each);
    }
}

/// How long a page may take to load, and the browser to answer anything else.
const load_timeout_ms = 30_000;
const answer_timeout_ms = 10_000;

/// How long an action is given to begin a navigation, before what it did is told.
const settle_ms = 150;

/// What the tools say of the page an argument names.
const page_is = "The page, by its id; the thread's newest unless given";

const all = [_]Tool{
    .{
        .name = "browser_navigate",
        .description = "Takes a page of the thread's in the browser to an address, back or forward an entry of its history, loads it again, or closes it; with `new`, or where the thread has none, opens a page at the address. The person sees the pages beside the chat. Waits till the page loads, then gives its id, title and address, or the browser's words for why it could not go there.",
        .parameters = typebox.of(NavigateArguments),
        .work = .{ .task = navigate },
    },
    .{
        .name = "browser_snapshot",
        .description = "Reads a page as a screen reader does: a line for each thing on it, nested — its role, its name, its states in brackets, `[ref=e12]` for the element, `: value` for what is in a field. Act on the elements by their refs, which last till the page shows another document. Also tells a dialog that holds the page, the messages of its console since the last snapshot, and the thread's other pages.",
        .parameters = typebox.of(PageArguments),
        .work = .{ .task = snapshotOf },
    },
    .{
        .name = "browser_act",
        .description = "Acts on a page as a person does, on an element by its ref from the snapshot, or at `x`, `y` in its CSS pixels: click (`button`, `clicks`), hover, type (`text`, at the caret of the element focused, `clear` replacing what is there, `submit` pressing Enter after), press (`key` as the DOM names it — Enter, Tab, ArrowDown, a — with `modifiers`, to what has the focus), select (`values` of a <select>, by value or label), scroll (`delta_x`, `delta_y` in pixels over the element or the page's middle), dialog (answers the dialog that holds the page: `accept`, `text` for a prompt). Waits for a navigation it begins, then gives the page's title and address.",
        .parameters = typebox.of(ActArguments),
        .work = .{ .task = act },
    },
    .{
        .name = "browser_evaluate",
        .description = "Runs a JavaScript expression in a page, as its own script, awaiting a promise it gives: its value as JSON, or the error it threw.",
        .parameters = typebox.of(EvaluateArguments),
        .work = .{ .task = evaluate },
    },
    .{
        .name = "browser_wait",
        .description = "Waits till a page shows `text`, no longer shows `gone`, and is at an address holding `url` — each given, case counting — or for `ms` alone; at most `timeout_ms`.",
        .parameters = typebox.of(WaitArguments),
        .work = .{ .task = wait },
    },
};

const PageArguments = struct {
    page: ?[]const u8 = null,

    pub const schema = .{ .page = .{ .description = page_is } };
};

const NavigateArguments = struct {
    url: ?[]const u8 = null,
    go: ?enum { back, forward, reload, close } = null,
    new: bool = false,
    page: ?[]const u8 = null,

    pub const schema = .{
        .url = .{ .description = "Where to go: an address with its scheme, or a host and its path, reached over https — http for localhost and an IP address" },
        .go = .{ .description = "Instead of an address: back or forward an entry of the page's history, load it again, or close it" },
        .new = .{ .description = "Open a new page at the address, beside the thread's others" },
        .page = .{ .description = page_is },
    };
};

const ActArguments = struct {
    action: enum { click, hover, type, press, select, scroll, dialog },
    ref: ?[]const u8 = null,
    x: ?f64 = null,
    y: ?f64 = null,
    button: enum { left, middle, right } = .left,
    clicks: u32 = 1,
    text: ?[]const u8 = null,
    clear: bool = false,
    submit: bool = false,
    key: ?[]const u8 = null,
    modifiers: []const keys.Modifier = &.{},
    values: []const []const u8 = &.{},
    delta_x: f64 = 0,
    delta_y: f64 = 0,
    accept: bool = true,
    page: ?[]const u8 = null,

    pub const schema = .{
        .action = .{ .description = "What to do" },
        .ref = .{ .description = "The element, by its ref from the snapshot" },
        .x = .{ .description = "Where across the page, in CSS pixels, with `y`, instead of a ref" },
        .y = .{ .description = "Where down the page, in CSS pixels, with `x`" },
        .button = .{ .description = "The button a click presses" },
        .clicks = .{ .description = "How many clicks: 2 for a double click", .minimum = 1, .maximum = 3 },
        .text = .{ .description = "What to type, as it is; or what a prompt is answered with" },
        .clear = .{ .description = "Replace what the field holds with the text" },
        .submit = .{ .description = "Press Enter after typing" },
        .key = .{ .description = "The key to press, as the DOM names it: Enter, Tab, Escape, ArrowDown, PageDown, F5, a" },
        .modifiers = .{ .description = "The keys held as it is pressed" },
        .values = .{ .description = "The options of a <select> to choose, by value or label" },
        .delta_x = .{ .description = "Pixels to scroll right; negative, left" },
        .delta_y = .{ .description = "Pixels to scroll down; negative, up" },
        .accept = .{ .description = "Accept the dialog, or dismiss it" },
        .page = .{ .description = page_is },
    };
};

const EvaluateArguments = struct {
    expression: []const u8,
    page: ?[]const u8 = null,

    pub const schema = .{
        .expression = .{ .description = "The JavaScript expression" },
        .page = .{ .description = page_is },
    };
};

const WaitArguments = struct {
    text: ?[]const u8 = null,
    gone: ?[]const u8 = null,
    url: ?[]const u8 = null,
    ms: ?u32 = null,
    timeout_ms: u32 = 15_000,
    page: ?[]const u8 = null,

    pub const schema = .{
        .text = .{ .description = "Text the page is to show" },
        .gone = .{ .description = "Text the page is to show no more" },
        .url = .{ .description = "What the page's address is to hold" },
        .ms = .{ .description = "How long to wait, where nothing else is awaited", .minimum = 1, .maximum = 60_000 },
        .timeout_ms = .{ .description = "How long to wait at most", .minimum = 1, .maximum = 60_000 },
        .page = .{ .description = page_is },
    };
};

/// A run of a browser tool: what it asks of the browser, and the browser's words for why the last ask failed.
const Browsing = struct {
    run: *const Tool.Run,
    browser: *Browser,
    failure: []const u8 = "",

    fn of(context: ?*anyopaque, run: *const Tool.Run) Browsing {
        return .{ .run = run, .browser = @ptrCast(@alignCast(context.?)), .failure = "" };
    }

    fn ask(browsing: *Browsing, op: Asked.Op, timeout_ms: u32) ![]const u8 {
        const run = browsing.run;
        return Asked.ask(run.runtime, browsing.browser, run.waits, run.arena, run.thread, op, timeout_ms, &browsing.failure);
    }

    /// The thread's pages, and the page `page` — none, the newest — where the thread has one.
    fn state(browsing: *Browsing, page: ?[]const u8) !Asked.State {
        return foundation.json.decode(Asked.State, browsing.run.arena, try browsing.ask(.{ .state = page }, answer_timeout_ms));
    }

    /// The page `page` — none, the newest — as the agent reads it; error.Failed where the thread has none.
    fn shown(browsing: *Browsing, page: ?[]const u8) !Asked.Shown {
        return (try browsing.state(page)).page orelse {
            browsing.failure = "the thread has no page open: navigate to an address to open one";
            return error.Failed;
        };
    }

    /// The browser's answer to `method` with `params` on the page `page`.
    fn command(browsing: *Browsing, page: []const u8, method: []const u8, params: anytype) !std.json.Value {
        const Params = @TypeOf(params);
        if (@typeInfo(Params) == .@"struct" and @typeInfo(Params).@"struct".is_tuple) @compileError("a command's params are an object, which a tuple is written as no more: give `Cdp.none`");
        const arena = browsing.run.arena;
        const sent = try foundation.json.encode(arena, params);
        const answer = try browsing.ask(.{ .command = .{ .page = page, .method = method, .params = sent } }, answer_timeout_ms);
        return std.json.parseFromSliceLeaky(std.json.Value, arena, answer, .{});
    }

    /// The browser's answer to an input sent to the page `page` — the mouse, a key, text — or to a script run on it;
    /// none where a dialog came to hold the page first, as an alert a click opens holds the input till it is answered,
    /// the answer then left for the loop to let go of.
    fn input(browsing: *Browsing, page: []const u8, method: []const u8, params: anytype) !?std.json.Value {
        const run = browsing.run;
        const sent = try foundation.json.encode(run.arena, params);
        const pending = try Asked.start(run.runtime, browsing.browser, run.waits, run.thread, .{ .command = .{ .page = page, .method = method, .params = sent } });
        defer pending.release();
        var waited: u32 = 0;
        while (true) : (waited += poll_ms) {
            if (pending.wait(run.runtime.host.io, poll_ms, run.arena, &browsing.failure)) |answer| {
                return try std.json.parseFromSliceLeaky(std.json.Value, run.arena, answer, .{});
            } else |err| switch (err) {
                error.TimedOut => {},
                else => return err,
            }
            if ((try browsing.shown(page)).dialog != null) return null;
            if (waited >= answer_timeout_ms) return error.TimedOut;
        }
    }

    /// Sleeps `ms`, waking as a stop comes.
    fn pause(browsing: *Browsing, ms: u32) !void {
        const io = browsing.run.runtime.host.io;
        const due = std.Io.Clock.awake.now(io).addDuration(.fromMilliseconds(ms));
        while (true) {
            const left = std.Io.Clock.awake.now(io).durationTo(due).toMilliseconds();
            if (left <= 0) return;
            browsing.run.waits.untilNews(@intCast(left)) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.Unexpected => return error.Unexpected,
            };
        }
    }

    /// What a run that failed tells: the browser's words, or how long it waited; anything else fails the call.
    fn refused(browsing: *const Browsing, err: anyerror) anyerror!Tool.Output {
        return switch (err) {
            error.Failed => .{ .outcome = .refused, .text = browsing.failure },
            error.TimedOut => .{ .outcome = .refused, .text = "the browser gave no answer in time" },
            else => err,
        };
    }
};

/// A refusal of what the model asked, in words it can act on.
fn refusal(text: []const u8) Tool.Output {
    return .{ .outcome = .refused, .text = text };
}

fn navigate(context: ?*anyopaque, run: *const Tool.Run) anyerror!Tool.Output {
    var browsing: Browsing = .of(context, run);
    return navigating(&browsing) catch |err| browsing.refused(err);
}

fn navigating(browsing: *Browsing) !Tool.Output {
    const arena = browsing.run.arena;
    const given = try foundation.json.decode(NavigateArguments, arena, browsing.run.arguments);
    if ((given.url == null) == (given.go == null)) return refusal("Give an address, or where to go: one of `url` and `go`.");
    if (given.url) |typed| {
        const url = addressOf(arena, typed) catch return refusal("That is no address: give one with its scheme, or a host and its path.");
        const pages = (try browsing.state(null)).pages;
        const op: Asked.Op = if (given.new or pages.len == 0) .{ .open = url } else .{ .navigate = .{ .page = (try browsing.shown(given.page)).id, .url = url } };
        return told(arena, try decodedState(arena, try browsing.ask(op, load_timeout_ms)), "");
    }
    const page = try browsing.shown(given.page);
    switch (given.go.?) {
        .close => return told(arena, try decodedState(arena, try browsing.ask(.{ .close = page.id }, answer_timeout_ms)), "The page is closed."),
        .reload => _ = try browsing.command(page.id, "Page.reload", Browser.Cdp.none),
        .back, .forward => {
            const history = try browsing.command(page.id, "Page.getNavigationHistory", Browser.Cdp.none);
            const at: i64 = @intFromFloat(Browser.Cdp.numberOf(history, "currentIndex") orelse 0);
            const entries = (Browser.Cdp.memberOf(history, "entries") orelse return error.Unexpected).array.items;
            const to = if (given.go.? == .back) at - 1 else at + 1;
            if (to < 0 or to >= entries.len) return refusal(if (given.go.? == .back) "The page has no entry to go back to." else "The page has no entry to go forward to.");
            const entry = Browser.Cdp.numberOf(entries[@intCast(to)], "id") orelse return error.Unexpected;
            _ = try browsing.command(page.id, "Page.navigateToHistoryEntry", .{ .entryId = @as(i64, @intFromFloat(entry)) });
        },
    }
    return told(arena, try decodedState(arena, try browsing.ask(.{ .load = .{ .page = page.id, .before = page.document } }, load_timeout_ms)), "");
}

fn decodedState(arena: Allocator, json: []const u8) !Asked.State {
    return foundation.json.decode(Asked.State, arena, json);
}

/// The address `typed` names: itself where it has a scheme; a host and its path reached over https, over http where it
/// is this machine's own or an IP address; error.NotAnAddress where it is neither.
pub fn addressOf(arena: Allocator, typed: []const u8) ![]const u8 {
    const text = std.mem.trim(u8, typed, " \t\r\n");
    if (hasScheme(text)) return text;
    if (text.len == 0 or std.mem.indexOfAny(u8, text, " \t\r\n") != null) return error.NotAnAddress;
    const host = text[0 .. std.mem.indexOfAny(u8, text, "/?#") orelse text.len];
    const name = if (std.mem.lastIndexOfScalar(u8, host, ':')) |colon| host[0..colon] else host;
    const local = std.mem.eql(u8, name, "localhost") or std.mem.eql(u8, name, "[::1]") or isAddress(name);
    if (local) return std.mem.concat(arena, u8, &.{ "http://", text });
    if (std.mem.indexOfScalar(u8, name, '.') == null) return error.NotAnAddress;
    return std.mem.concat(arena, u8, &.{ "https://", text });
}

/// Whether `text` begins with a scheme, as RFC 3986 writes one — a letter, then letters, digits, `+`, `-` and `.`, then
/// a colon — not a host and its port, as `localhost:5173` is.
fn hasScheme(text: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return false;
    if (colon == 0 or !std.ascii.isAlphabetic(text[0])) return false;
    for (text[0..colon]) |char| if (!std.ascii.isAlphanumeric(char) and char != '+' and char != '-' and char != '.') return false;
    const after = text[colon + 1 ..];
    const port = after[0 .. std.mem.indexOfAny(u8, after, "/?#") orelse after.len];
    if (port.len == 0) return true;
    for (port) |char| if (!std.ascii.isDigit(char)) return true;
    return false;
}

/// Whether `name` is an IPv4 address.
fn isAddress(name: []const u8) bool {
    var parts = std.mem.splitScalar(u8, name, '.');
    var count: usize = 0;
    while (parts.next()) |part| : (count += 1) _ = std.fmt.parseInt(u8, part, 10) catch return false;
    return count == 4;
}

/// What a tool tells of the thread's pages after it acted: `done`, where it says something, then the page acted on —
/// its id, title and address — and what holds it.
fn told(arena: Allocator, state: Asked.State, done: []const u8) !Tool.Output {
    var notes: Tool.Notes = .{ .arena = arena };
    const page = state.page orelse return .{ .text = if (done.len > 0) done else "The thread has no page open." };
    try noteDialog(&notes, page);
    const line = try lineOf(arena, page);
    return .{ .text = if (done.len > 0) try std.mem.concat(arena, u8, &.{ done, "\n", line }) else line, .notes = notes.list.items };
}

/// A page's line: its id, its title and its address, and whether it is still loading.
fn lineOf(arena: Allocator, page: Asked.Shown) ![]const u8 {
    return std.fmt.allocPrint(arena, "page {s}: {f} {s}{s}", .{ page.id, std.json.fmt(page.title, .{}), page.url, if (page.loading) " (loading)" else "" });
}

fn noteDialog(notes: *Tool.Notes, page: Asked.Shown) !void {
    const dialog = page.dialog orelse return;
    try notes.add("a dialog holds the page: {s} {f}: answer it with browser_act dialog", .{ dialog.kind, std.json.fmt(dialog.message, .{}) });
}

fn snapshotOf(context: ?*anyopaque, run: *const Tool.Run) anyerror!Tool.Output {
    var browsing: Browsing = .of(context, run);
    return snapshotting(&browsing) catch |err| browsing.refused(err);
}

fn snapshotting(browsing: *Browsing) !Tool.Output {
    const arena = browsing.run.arena;
    const given = try foundation.json.decode(PageArguments, arena, browsing.run.arguments);
    const page = try browsing.shown(given.page);
    // A page a dialog holds reads nothing till it is answered.
    if (page.dialog != null) return told(arena, .{ .page = page }, "");
    const taken = try foundation.json.decode(Asked.Snapshot, arena, try browsing.ask(.{ .snapshot = page.id }, answer_timeout_ms));
    const shown = taken.state.page orelse page;
    var notes: Tool.Notes = .{ .arena = arena };
    for (shown.messages) |message| try notes.add("console {s}: {s}", .{ @tagName(message.level), message.text });
    for (taken.state.pages) |other| {
        if (std.mem.eql(u8, other.id, shown.id)) continue;
        try notes.add("another page of the thread's: {s}: {f} {s}", .{ other.id, std.json.fmt(other.title, .{}), other.url });
    }
    const tree = try snapshot.written(arena, taken.tree);
    return .{ .text = try std.mem.concat(arena, u8, &.{ try lineOf(arena, shown), "\n", tree }), .notes = notes.list.items };
}

fn act(context: ?*anyopaque, run: *const Tool.Run) anyerror!Tool.Output {
    var browsing: Browsing = .of(context, run);
    return acting(&browsing) catch |err| browsing.refused(err);
}

/// Where an action is aimed: an element by the browser's node id, a point of the page, or neither.
const Aim = union(enum) { element: i64, point: Point, none };
const Point = struct { x: f64, y: f64 };

fn acting(browsing: *Browsing) !Tool.Output {
    const arena = browsing.run.arena;
    const given = try foundation.json.decode(ActArguments, arena, browsing.run.arguments);
    const page = try browsing.shown(given.page);
    if (given.action == .dialog) {
        if (page.dialog == null) return refusal("No dialog holds the page.");
        _ = try browsing.command(page.id, "Page.handleJavaScriptDialog", .{ .accept = given.accept, .promptText = given.text });
        return told(arena, try browsing.state(page.id), if (given.accept) "The dialog is accepted." else "The dialog is dismissed.");
    }
    if (page.dialog != null) return told(arena, .{ .page = page }, "Nothing is done: a dialog holds the page.");
    const aim: Aim = if (given.ref) |ref| aimed: {
        if (!page.current) return refusal("The page shows another document than its snapshot, or none was taken: take a snapshot, then act by its refs.");
        break :aimed .{ .element = snapshot.nodeOf(ref) orelse return refusal("That is no ref: give one as the snapshot does, as e12.") };
    } else if (given.x != null and given.y != null) .{ .point = .{ .x = given.x.?, .y = given.y.? } } else .none;
    switch (given.action) {
        .click, .hover => {
            const point = try pointOf(browsing, page, aim) orelse return refusal("Give the element by its ref, or a point by `x` and `y`.");
            const moved = try mouse(browsing, page.id, "mouseMoved", point, given.button, 0, 0);
            if (given.action == .click and moved and try mouse(browsing, page.id, "mousePressed", point, given.button, buttonsOf(given.button), given.clicks)) {
                _ = try mouse(browsing, page.id, "mouseReleased", point, given.button, 0, given.clicks);
            }
        },
        .type => try typeInto(browsing, page, aim, given),
        .press => {
            const name = given.key orelse return refusal("Give the key to press.");
            (try press(browsing, page.id, name, given.modifiers)) orelse return refusal("No key has that name: give it as the DOM names it, as Enter, ArrowDown or a.");
        },
        .select => {
            const element = switch (aim) {
                .element => |node| node,
                else => return refusal("Give the <select> by its ref."),
            };
            if (try selected(browsing, page.id, element, given.values)) |why| return refusal(why);
        },
        .scroll => {
            const point = try pointOf(browsing, page, aim) orelse Point{ .x = @floatFromInt(page.width / 2), .y = @floatFromInt(page.height / 2) };
            _ = try browsing.input(page.id, "Input.dispatchMouseEvent", .{ .type = "mouseWheel", .x = point.x, .y = point.y, .deltaX = given.delta_x, .deltaY = given.delta_y });
        },
        .dialog => unreachable,
    }
    return settled(browsing, page);
}

/// What an action did, once a navigation it began loaded: the page's line, and whether it shows another document now.
fn settled(browsing: *Browsing, before: Asked.Shown) !Tool.Output {
    const arena = browsing.run.arena;
    try browsing.pause(settle_ms);
    var state = try browsing.state(before.id);
    if (state.page != null and state.page.?.loading) {
        if (browsing.ask(.{ .load = .{ .page = before.id, .before = before.document } }, load_timeout_ms)) |loaded| {
            state = try decodedState(arena, loaded);
        } else |err| switch (err) {
            error.TimedOut => {},
            else => return err,
        }
    }
    var output = try told(arena, state, "Done.");
    const now = state.page orelse return output;
    const moved = now.document != null and before.document != null and !std.mem.eql(u8, now.document.?, before.document.?);
    if (moved) output.notes = try std.mem.concat(arena, []const u8, &.{ output.notes, &.{"the page shows another document now: take a snapshot to act on it"} });
    return output;
}

fn buttonsOf(button: @FieldType(ActArguments, "button")) u32 {
    return switch (button) {
        .left => 1,
        .right => 2,
        .middle => 4,
    };
}

/// The point an action is aimed at: an element's middle, scrolled into view first; a point given; none. error.Failed
/// where the element shows nothing to aim at.
fn pointOf(browsing: *Browsing, page: Asked.Shown, aim: Aim) !?Point {
    const node = switch (aim) {
        .element => |node| node,
        .point => |point| return point,
        .none => return null,
    };
    _ = try browsing.command(page.id, "DOM.scrollIntoViewIfNeeded", .{ .backendNodeId = node });
    const found = try browsing.command(page.id, "DOM.getContentQuads", .{ .backendNodeId = node });
    const quads = Browser.Cdp.memberOf(found, "quads") orelse return error.Unexpected;
    for (quads.array.items) |quad| {
        if (quad != .array or quad.array.items.len != 8) continue;
        var corners: [8]f64 = undefined;
        for (quad.array.items, &corners) |each, *corner| corner.* = numberOf(each);
        const area = @abs((corners[0] - corners[4]) * (corners[3] - corners[7]));
        if (area < 1) continue;
        return .{ .x = (corners[0] + corners[2] + corners[4] + corners[6]) / 4, .y = (corners[1] + corners[3] + corners[5] + corners[7]) / 4 };
    }
    browsing.failure = "the element shows nothing to aim at: it may be hidden, or empty";
    return error.Failed;
}

fn numberOf(value: std.json.Value) f64 {
    return switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => 0,
    };
}

/// Sends the page the mouse's `kind` of event at `point`: whether the page took it, not held by a dialog it opened.
fn mouse(browsing: *Browsing, page: []const u8, kind: []const u8, point: Point, button: @FieldType(ActArguments, "button"), buttons: u32, clicks: u32) !bool {
    const sent = .{ .type = kind, .x = point.x, .y = point.y, .button = @tagName(button), .buttons = buttons, .clickCount = clicks };
    return try browsing.input(page, "Input.dispatchMouseEvent", sent) != null;
}

/// Types the text given where the element aimed at — focused first — or the page's focus is: what is there replaced
/// first where `clear` says, Enter pressed after where `submit` does.
fn typeInto(browsing: *Browsing, page: Asked.Shown, aim: Aim, given: ActArguments) !void {
    switch (aim) {
        .element => |node| _ = try browsing.command(page.id, "DOM.focus", .{ .backendNodeId = node }),
        .point => |point| {
            if (!try mouse(browsing, page.id, "mousePressed", point, .left, 1, 1)) return;
            if (!try mouse(browsing, page.id, "mouseReleased", point, .left, 0, 1)) return;
        },
        .none => {},
    }
    if (given.clear) _ = try press(browsing, page.id, "a", &.{.Control});
    if (given.text) |text| if (try browsing.input(page.id, "Input.insertText", .{ .text = text }) == null) return;
    if (given.submit) _ = try press(browsing, page.id, "Enter", &.{});
}

/// Presses and lets go of the key `name` with `modifiers` held; null where no key has that name.
fn press(browsing: *Browsing, page: []const u8, name: []const u8, modifiers: []const keys.Modifier) !?void {
    var buffer: [8]u8 = undefined;
    const key = keys.pressed(name, modifiers, &buffer) catch return null;
    const down = if (key.text != null) "keyDown" else "rawKeyDown";
    const pressing = .{ .type = down, .key = key.key, .code = key.code, .text = key.text, .modifiers = key.modifiers, .windowsVirtualKeyCode = key.key_code, .commands = key.commands };
    if (try browsing.input(page, "Input.dispatchKeyEvent", pressing) == null) return;
    _ = try browsing.input(page, "Input.dispatchKeyEvent", .{ .type = "keyUp", .key = key.key, .code = key.code, .modifiers = key.modifiers, .windowsVirtualKeyCode = key.key_code });
}

/// What chooses the options of a <select> given, by value or label, as a person's choosing does — the others let go
/// of, one alone where it takes one — and tells of it as a person's choosing is told: the labels chosen.
const select_options =
    \\function (values) {
    \\  if (!(this instanceof HTMLSelectElement)) throw new Error("the element is no <select>");
    \\  const options = [...this.options];
    \\  const chosen = options.filter((option) => values.includes(option.value) || values.includes(option.label.trim()));
    \\  if (chosen.length === 0) throw new Error("no option has that value or label: " + options.map((option) => option.label.trim()).join(", "));
    \\  for (const option of options) option.selected = this.multiple ? chosen.includes(option) : option === chosen[0];
    \\  this.dispatchEvent(new Event("input", { bubbles: true }));
    \\  this.dispatchEvent(new Event("change", { bubbles: true }));
    \\  return chosen.map((option) => option.label.trim());
    \\}
;

/// Chooses `values` in the <select> `node`: null where it did, else the words for why it could not.
fn selected(browsing: *Browsing, page: []const u8, node: i64, values: []const []const u8) !?[]const u8 {
    const resolved = try browsing.command(page, "DOM.resolveNode", .{ .backendNodeId = node });
    const object = Browser.Cdp.textOf(Browser.Cdp.memberOf(resolved, "object") orelse return error.Unexpected, "objectId") orelse return error.Unexpected;
    const choosing = .{ .objectId = object, .functionDeclaration = select_options, .arguments = .{.{ .value = values }}, .returnByValue = true };
    return thrownOf(try browsing.input(page, "Runtime.callFunctionOn", choosing) orelse return null);
}

/// The words of what a script threw, where its run threw.
fn thrownOf(ran: std.json.Value) ?[]const u8 {
    const details = Browser.Cdp.memberOf(ran, "exceptionDetails") orelse return null;
    if (Browser.Cdp.memberOf(details, "exception")) |exception| if (Browser.Cdp.textOf(exception, "description")) |description| return description;
    return Browser.Cdp.textOf(details, "text") orelse "it threw";
}

fn evaluate(context: ?*anyopaque, run: *const Tool.Run) anyerror!Tool.Output {
    var browsing: Browsing = .of(context, run);
    return evaluating(&browsing) catch |err| browsing.refused(err);
}

fn evaluating(browsing: *Browsing) !Tool.Output {
    const arena = browsing.run.arena;
    const given = try foundation.json.decode(EvaluateArguments, arena, browsing.run.arguments);
    const page = try browsing.shown(given.page);
    if (page.dialog != null) return told(arena, .{ .page = page }, "Nothing is run: a dialog holds the page.");
    const running = .{ .expression = given.expression, .awaitPromise = true, .returnByValue = true, .userGesture = true };
    const ran = try browsing.input(page.id, "Runtime.evaluate", running) orelse {
        return told(arena, try browsing.state(page.id), "The script opened a dialog, which holds it till it is answered.");
    };
    if (thrownOf(ran)) |thrown| return refusal(thrown);
    return .{ .text = try valueOf(arena, Browser.Cdp.memberOf(ran, "result") orelse return error.Unexpected) };
}

/// A value a script gave, as the model reads it: JSON, or what JSON cannot write — undefined, NaN, a big integer — as
/// the browser names it.
fn valueOf(arena: Allocator, result: std.json.Value) ![]const u8 {
    if (Browser.Cdp.memberOf(result, "value")) |value| return foundation.json.encode(arena, value);
    if (Browser.Cdp.textOf(result, "unserializableValue")) |unwritten| return unwritten;
    return Browser.Cdp.textOf(result, "description") orelse Browser.Cdp.textOf(result, "type") orelse "undefined";
}

fn wait(context: ?*anyopaque, run: *const Tool.Run) anyerror!Tool.Output {
    var browsing: Browsing = .of(context, run);
    return waiting(&browsing) catch |err| browsing.refused(err);
}

/// How often a wait reads the page again.
const poll_ms = 250;

fn waiting(browsing: *Browsing) !Tool.Output {
    const arena = browsing.run.arena;
    const given = try foundation.json.decode(WaitArguments, arena, browsing.run.arguments);
    if (given.text == null and given.gone == null and given.url == null) {
        try browsing.pause(given.ms orelse return refusal("Give what to wait for: `text`, `gone`, `url`, or `ms`."));
        return .{ .text = try std.fmt.allocPrint(arena, "Waited {d} ms.", .{given.ms.?}) };
    }
    const page = try browsing.shown(given.page);
    const expression = try std.fmt.allocPrint(arena, "(() => {{ const shown = document.body ? document.body.innerText : \"\"; return [{f} === null || shown.includes({f}), {f} === null || !shown.includes({f})]; }})()", .{
        std.json.fmt(given.text, .{}), std.json.fmt(given.text, .{}), std.json.fmt(given.gone, .{}), std.json.fmt(given.gone, .{}),
    });
    const io = browsing.run.runtime.host.io;
    const started = std.Io.Clock.awake.now(io);
    while (true) {
        const now = try browsing.shown(page.id);
        var holds = given.url == null or std.mem.indexOf(u8, now.url, given.url.?) != null;
        if (holds and now.dialog == null and (given.text != null or given.gone != null)) {
            const ran = try browsing.input(page.id, "Runtime.evaluate", .{ .expression = expression, .returnByValue = true }) orelse .null;
            const both = Browser.Cdp.memberOf(Browser.Cdp.memberOf(ran, "result") orelse .null, "value") orelse .null;
            holds = both == .array and both.array.items.len == 2 and both.array.items[0] == .bool and both.array.items[0].bool and both.array.items[1] == .bool and both.array.items[1].bool;
        }
        const waited = started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
        if (holds) return told(arena, .{ .page = now }, try std.fmt.allocPrint(arena, "Waited {d} ms.", .{waited}));
        if (waited >= given.timeout_ms) return refusal(try std.fmt.allocPrint(arena, "Not so after {d} ms: {s}", .{ waited, try lineOf(arena, now) }));
        try browsing.pause(poll_ms);
    }
}

test "an address is taken in every spelling of one meaning" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("https://example.com/a", try addressOf(arena, "https://example.com/a"));
    try std.testing.expectEqualStrings("https://example.com/docs", try addressOf(arena, " example.com/docs "));
    try std.testing.expectEqualStrings("http://localhost:5173/", try addressOf(arena, "localhost:5173/"));
    try std.testing.expectEqualStrings("http://127.0.0.1:8080", try addressOf(arena, "127.0.0.1:8080"));
    try std.testing.expectEqualStrings("about:blank", try addressOf(arena, "about:blank"));
    try std.testing.expectEqualStrings("data:text/html,<p>a b</p>", try addressOf(arena, "data:text/html,<p>a b</p>"));
    try std.testing.expectEqualStrings("http://localhost:5173", try addressOf(arena, "localhost:5173"));
    try std.testing.expectError(error.NotAnAddress, addressOf(arena, "zig std io"));
    try std.testing.expectError(error.NotAnAddress, addressOf(arena, "octoii"));
}
