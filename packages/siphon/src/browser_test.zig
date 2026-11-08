//! The browser tools on a real Chromium of this machine's, each run as a call runs it — in a task of its own, asking
//! the browser through the loop the test pumps — on pages a thread opens: gone to, read by their accessibility tree,
//! typed into, clicked, chosen in and scripted by the refs that tree gives, a dialog answered, history gone back on,
//! and a page opened and closed beside the first.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Siphon = @import("Siphon.zig");
const threads = @import("threads.zig");
const tools = @import("tools.zig");
const Waits = @import("runtime.zig").Waits;
const testing = @import("testing.zig");
const beak = @import("beak.zig");

/// What a call of a tool told the model, and whether it did what it was asked.
const Told = struct { done: bool, text: []const u8 };

/// A tool run in a task of its own, as a call runs it, while the test pumps the loop it asks the browser through.
const Ran = struct {
    siphon: *Siphon,
    tool: tools.Tool,
    run: tools.Tool.Run,
    output: anyerror!tools.Tool.Output = error.NotRun,
    done: std.atomic.Value(bool) = .init(false),

    fn go(ran: *Ran) void {
        ran.output = ran.tool.work.task(ran.tool.context, &ran.run);
        ran.done.store(true, .release);
        ran.siphon.runtime.wake();
    }

    fn ended(ran: *Ran) bool {
        return ran.done.load(.acquire);
    }
};

/// The tool `name` called with `arguments` for the thread `tid`: what it told, in `arena`.
fn call(siphon: *Siphon, arena: Allocator, tid: []const u8, name: []const u8, arguments: []const u8) !Told {
    var run_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer run_arena.deinit();
    var waits: Waits = .{};
    defer waits.close();
    const key = try arena.dupe(u8, &try siphon.runtime.volume.mint(siphon.runtime.now()));
    var ran: Ran = .{
        .siphon = siphon,
        .tool = siphon.tools.named(name) orelse return error.NoSuchTool,
        .run = .{ .arena = run_arena.allocator(), .runtime = siphon.runtime, .host = &siphon.tools.host, .thread = tid, .arguments = arguments, .key = key, .writes = .anywhere, .waits = &waits },
    };
    var task = try std.testing.io.concurrent(Ran.go, .{&ran});
    testing.pumpUntil(siphon, &ran, Ran.ended) catch |err| {
        waits.stop();
        task.await(std.testing.io);
        return err;
    };
    task.await(std.testing.io);
    const output = try ran.output;
    // What it told may be its run's own text, which goes with its run's memory.
    return .{ .done = output.outcome == .done, .text = try arena.dupe(u8, try tools.Tool.told(arena, output)) };
}

/// The ref the snapshot `text` gives the thing whose line holds `named`.
fn refOf(text: []const u8, named: []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, named) == null) continue;
        const start = (std.mem.indexOf(u8, line, "[ref=") orelse continue) + "[ref=".len;
        const end = std.mem.indexOfScalarPos(u8, line, start, ']') orelse continue;
        return line[start..end];
    }
    std.debug.print("no line holds {s} in:\n{s}\n", .{ named, text });
    return error.NoSuchThing;
}

fn expectHolds(text: []const u8, part: []const u8) !void {
    if (std.mem.indexOf(u8, text, part) != null) return;
    std.debug.print("expected to hold {s}:\n{s}\n", .{ part, text });
    return error.TestExpectedHolds;
}

const form =
    "data:text/html,<title>Form</title>" ++
    "<label>Name <input id=n></label>" ++
    "<select id=s aria-label=Choice><option value=1>One</option><option value=2>Two</option></select>" ++
    "<button onclick=\"document.getElementById('out').textContent='Thanks '+document.getElementById('n').value; console.log('sent', 1)\">Send</button>" ++
    "<button onclick=\"document.title = confirm('Sure?') ? 'yes' : 'no'\">Ask</button>" ++
    "<p id=out></p>";

test "a thread's model goes to a page, reads it, and acts on it by the refs it read, as a person does" {
    const chromium = testing.chromium() orelse return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const machine = try testing.openLocalMachine();
    defer _ = beak.h.beak_close(machine);
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const profile = try std.fs.path.join(arena, &.{ root, "profile" });
    const siphon = try Siphon.open(std.testing.allocator, .{ .io = std.testing.io, .clock = clock.clock(), .machine = machine, .home = root, .browser = chromium, .browser_profile = profile }, .{});
    defer siphon.close();
    const thread = try threads.create(siphon.runtime, arena, .{ .workspace = root }, "create");

    // With no page open, going somewhere opens one, told once it loaded.
    const went = try call(siphon, arena, thread, "browser_navigate", try std.fmt.allocPrint(arena, "{{\"url\":{f}}}", .{std.json.fmt(form, .{})}));
    try std.testing.expect(went.done);
    try expectHolds(went.text, "\"Form\" data:text/html");

    // Read, it names each thing with the ref to act on it by.
    const read = try call(siphon, arena, thread, "browser_snapshot", "{}");
    try expectHolds(read.text, "textbox \"Name\"");
    const name = try refOf(read.text, "textbox \"Name\"");
    const send = try refOf(read.text, "button \"Send\"");
    const ask = try refOf(read.text, "button \"Ask\"");
    const choice = try refOf(read.text, "\"Choice\"");

    // Typed into and clicked, it shows what it was to; its console's message told by the next snapshot.
    try std.testing.expect((try call(siphon, arena, thread, "browser_act", try std.fmt.allocPrint(arena, "{{\"action\":\"type\",\"ref\":\"{s}\",\"text\":\"Ada\"}}", .{name}))).done);
    try std.testing.expect((try call(siphon, arena, thread, "browser_act", try std.fmt.allocPrint(arena, "{{\"action\":\"click\",\"ref\":\"{s}\"}}", .{send}))).done);
    try expectHolds((try call(siphon, arena, thread, "browser_wait", "{\"text\":\"Thanks Ada\"}")).text, "Waited");
    const again = try call(siphon, arena, thread, "browser_snapshot", "{}");
    try expectHolds(again.text, try std.fmt.allocPrint(arena, "textbox \"Name\" [ref={s}]: \"Ada\"\n- combobox", .{name}));
    try expectHolds(again.text, "console log: sent 1");

    // Chosen in, typed over and pressed on, its script reads what was done.
    try std.testing.expect((try call(siphon, arena, thread, "browser_act", try std.fmt.allocPrint(arena, "{{\"action\":\"select\",\"ref\":\"{s}\",\"values\":[\"Two\"]}}", .{choice}))).done);
    try std.testing.expectEqualStrings("\"2\"", (try call(siphon, arena, thread, "browser_evaluate", "{\"expression\":\"document.getElementById('s').value\"}")).text);
    try std.testing.expect((try call(siphon, arena, thread, "browser_act", try std.fmt.allocPrint(arena, "{{\"action\":\"type\",\"ref\":\"{s}\",\"text\":\"Grace\",\"clear\":true}}", .{name}))).done);
    try std.testing.expect((try call(siphon, arena, thread, "browser_act", "{\"action\":\"press\",\"key\":\"Backspace\"}")).done);
    try std.testing.expectEqualStrings("\"Grac\"", (try call(siphon, arena, thread, "browser_evaluate", "{\"expression\":\"document.getElementById('n').value\"}")).text);
    const thrown = try call(siphon, arena, thread, "browser_evaluate", "{\"expression\":\"(() => { throw new Error('boom') })()\"}");
    try std.testing.expect(!thrown.done);
    try expectHolds(thrown.text, "boom");

    // A click that opens a dialog is told the dialog holds the page; answered, the page goes on.
    const asked = try call(siphon, arena, thread, "browser_act", try std.fmt.allocPrint(arena, "{{\"action\":\"click\",\"ref\":\"{s}\"}}", .{ask}));
    try expectHolds(asked.text, "a dialog holds the page: confirm \"Sure?\"");
    try std.testing.expect((try call(siphon, arena, thread, "browser_act", "{\"action\":\"dialog\",\"accept\":true}")).done);
    try std.testing.expectEqualStrings("\"yes\"", (try call(siphon, arena, thread, "browser_evaluate", "{\"expression\":\"document.title\"}")).text);

    // Gone elsewhere, the refs read before are refused; gone back, it is where it was.
    try expectHolds((try call(siphon, arena, thread, "browser_navigate", "{\"url\":\"data:text/html,<title>Second</title><h1>Second</h1>\"}")).text, "\"Second\"");
    const stale = try call(siphon, arena, thread, "browser_act", try std.fmt.allocPrint(arena, "{{\"action\":\"click\",\"ref\":\"{s}\"}}", .{send}));
    try std.testing.expect(!stale.done);
    try expectHolds(stale.text, "take a snapshot");
    try expectHolds((try call(siphon, arena, thread, "browser_navigate", "{\"go\":\"back\"}")).text, "data:text/html,<title>Form</title>");

    // A page opened beside it is the thread's newest, and the other is told of; closed, the first is the newest again.
    try std.testing.expect((try call(siphon, arena, thread, "browser_navigate", "{\"url\":\"about:blank\",\"new\":true}")).done);
    try expectHolds((try call(siphon, arena, thread, "browser_snapshot", "{}")).text, "another page of the thread's");
    try std.testing.expect((try call(siphon, arena, thread, "browser_navigate", "{\"go\":\"close\"}")).done);
    try expectHolds((try call(siphon, arena, thread, "browser_snapshot", "{}")).text, " data:text/html,<title>Form</title>");
}
