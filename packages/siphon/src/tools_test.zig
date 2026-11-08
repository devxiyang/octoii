//! The calls a thread's model makes, over a fake provider: each run by its tool and answered once, in the order the
//! model made them, then the model asked again, on what the person sent meanwhile too — a call of no tool, or of
//! arguments that do not fit, answered so; a stop answering the call it cut off; and a call that may have acted, cut
//! off by the host's end, never run twice.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const ai = @import("ai");
const Siphon = @import("Siphon.zig");
const threads = @import("threads.zig");
const log = @import("threads.zig").log;
const testing = @import("testing.zig");
const tools = @import("tools.zig");
const calls = @import("tools.zig").calls;
const compaction = @import("agent.zig").compaction;

const model = testing.model;
const streamed = testing.streamed;
const message = testing.message;
const call = testing.call;
const said = testing.said;
const expectEntries = testing.expectEntries;
const openOver = testing.openOver;
const Slow = testing.Slow;

/// Adds two numbers: read-only.
const add_tool: @import("tools.zig").Tool = .{
    .name = "add",
    .description = "Adds two numbers.",
    .parameters = "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"number\"},\"b\":{\"type\":\"number\"}},\"required\":[\"a\",\"b\"]}",
    .work = .{ .task = add },
};

fn add(_: ?*anyopaque, run: *const tools.Tool.Run) anyerror!tools.Tool.Output {
    const Numbers = struct { a: f64, b: f64 };
    const numbers = try foundation.json.decode(Numbers, run.arena, run.arguments);
    return .{ .text = try std.fmt.allocPrint(run.arena, "{d}", .{numbers.a + numbers.b}) };
}

/// A tool whose calls wait for each other: each arrives, then waits till `expected` have, and lingers as its arguments
/// say before it ends — so calls run one after another never meet.
const Meeting = struct {
    arrived: std.atomic.Value(u32) = .init(0),
    expected: u32,

    fn tool(meeting: *Meeting) @import("tools.zig").Tool {
        return .{ .name = "meet", .description = "Meets.", .parameters = "{\"type\":\"object\",\"properties\":{\"linger_ms\":{\"type\":\"integer\"}}}", .context = meeting, .work = .{ .task = run } };
    }

    /// Whether a call of it has arrived.
    fn begun(meeting: *Meeting) bool {
        return meeting.arrived.load(.acquire) > 0;
    }

    fn run(context: ?*anyopaque, given: *const tools.Tool.Run) anyerror!tools.Tool.Output {
        const meeting: *Meeting = @ptrCast(@alignCast(context.?));
        const Lingering = struct { linger_ms: i64 = 0 };
        const lingering = try foundation.json.decode(Lingering, given.arena, given.arguments);
        _ = meeting.arrived.fetchAdd(1, .acq_rel);
        const io = given.runtime.host.io;
        for (0..500) |_| {
            if (meeting.arrived.load(.acquire) >= meeting.expected) break;
            try io.sleep(.fromMilliseconds(10), .awake);
        } else return .{ .outcome = .refused, .text = "never met" };
        try io.sleep(.fromMilliseconds(lingering.linger_ms), .awake);
        return .{ .text = "met" };
    }
};

/// The sub-threads of the thread `tid`, by their ids.
fn subThreadsOf(siphon: *Siphon, arena: Allocator, tid: []const u8) ![]const []const u8 {
    var found: std.ArrayList([]const u8) = .empty;
    for (try threads.list(siphon.runtime, arena)) |row| {
        const parent = row.manifest.parent orelse continue;
        if (std.mem.eql(u8, parent.thread, tid)) try found.append(arena, row.id);
    }
    return found.items;
}

/// Pumps until the log of the thread `tid` holds `count` turns ended, and nothing waits in its inbox.
fn pumpUntilTurnsEnded(siphon: *Siphon, arena: Allocator, tid: []const u8, count: usize) !void {
    const Ended = struct {
        siphon: *Siphon,
        arena: Allocator,
        tid: []const u8,
        count: usize,

        fn reached(ended: *const @This()) bool {
            const entries = testing.entriesOf(ended.siphon, ended.arena, ended.tid) catch return false;
            var turns: usize = 0;
            for (entries) |entry| turns += @intFromBool(std.mem.eql(u8, entry, "turn-end"));
            const state = threads.state(ended.siphon.runtime, ended.arena, ended.tid) catch return false;
            return turns == ended.count and state.inbox.len == 0;
        }
    };
    const ended: Ended = .{ .siphon = siphon, .arena = arena, .tid = tid, .count = count };
    return testing.pumpUntil(siphon, &ended, Ended.reached);
}

test "a call is run by its tool, its result appended, and the model asked again with the result and the tools" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: ai.testing.Fake = .init(arena, &.{ try streamed(arena, &.{call("c1", "add", "{\"a\":1,\"b\":2}")}), try message(arena, "3") });
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try openOver(&clock, .memory, &providers);
    defer siphon.close();
    try siphon.tools.add(add_tool);
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m" }, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, said("what is 1 + 2?"), "op-1");
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try expectEntries(siphon, arena, tid, &.{ "system", "input", "reply", "result ok", "reply", "turn-end" });
    const sent = fake.requests.items[1];
    try std.testing.expect(testing.declares(sent.tools.?, "add"));
    const items = sent.input.?.parts;
    try std.testing.expectEqual(@as(usize, 4), items.len);
    try std.testing.expectEqualStrings("c1", items[2].function_call.call_id);
    try std.testing.expectEqualStrings("c1", items[3].function_call_output.call_id);
    try std.testing.expectEqualStrings("3", items[3].function_call_output.output.text);
    try std.testing.expect(items[3].function_call_output.octoii == null);
}

test "one long turn refused as too long is cut within it: the input that began it kept, then its latest call" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: ai.testing.Fake = .init(arena, &.{
        try streamed(arena, &.{call("c1", "add", "{\"a\":1,\"b\":2}")}),
        try streamed(arena, &.{call("c2", "add", "{\"a\":3,\"b\":4}")}),
        .{ .events = &.{}, .failure = .init(.context_overflow, "too long") },
        try message(arena, "1 + 2 is 3."),
        try message(arena, "7"),
    });
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try openOver(&clock, .memory, &providers);
    defer siphon.close();
    try siphon.tools.add(add_tool);
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m" }, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, said("add them"), "op-1");
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try expectEntries(siphon, arena, tid, &.{ "system", "input", "reply", "result ok", "reply", "result ok", "failure", "compaction", "system", "reply", "turn-end" });
    try std.testing.expectEqual(@as(usize, 5), fake.requests.items.len);

    // The recap covers the turn up to its latest call, its tools declared as ever, none to be called.
    const recapping = fake.requests.items[3];
    try std.testing.expectEqual(.none, recapping.tool_choice.?.mode);
    try std.testing.expect(testing.declares(recapping.tools.?, "add"));
    const covered = recapping.input.?.parts;
    try std.testing.expectEqual(@as(usize, 5), covered.len);
    try std.testing.expectEqualStrings("c1", covered[3].function_call_output.call_id);
    try std.testing.expectEqualStrings(compaction.instruction, covered[4].input_message.content.text);
    // Then the new window: told, the recap, the input that began the turn as it was given, its latest call and result.
    const sent = fake.requests.items[4].input.?.parts;
    try std.testing.expectEqual(@as(usize, 5), sent.len);
    try std.testing.expectEqualStrings("<recap>\n1 + 2 is 3.\n</recap>", sent[1].input_message.content.text);
    try std.testing.expectEqualStrings("add them", sent[2].input_message.content.text);
    try std.testing.expectEqualStrings("c2", sent[3].function_call.call_id);
    try std.testing.expectEqualStrings("7", sent[4].function_call_output.output.text);
}

/// Doubles a number: a tool added within a window.
const double_tool: @import("tools.zig").Tool = .{
    .name = "double",
    .description = "Doubles a number.",
    .parameters = "{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"number\"}},\"required\":[\"x\"]}",
    .work = .{ .task = double },
};

fn double(_: ?*anyopaque, run: *const tools.Tool.Run) anyerror!tools.Tool.Output {
    const Number = struct { x: f64 };
    return .{ .text = try std.fmt.allocPrint(run.arena, "{d}", .{(try foundation.json.decode(Number, run.arena, run.arguments)).x * 2}) };
}

test "a tool added within a window is declared from the next window: what a window declares never changes within it" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: ai.testing.Fake = .init(arena, &.{ try message(arena, "hi"), try message(arena, "again") });
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try openOver(&clock, .memory, &providers);
    defer siphon.close();
    try siphon.tools.add(add_tool);
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m" }, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, said("hello"), "op-1");
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try siphon.tools.add(double_tool);
    _ = try threads.deliver(siphon.runtime, arena, tid, said("and now?"), "op-2");
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try expectEntries(siphon, arena, tid, &.{ "system", "input", "reply", "turn-end", "input", "reply", "turn-end" });
    const first = fake.requests.items[0].tools.?;
    const second = fake.requests.items[1].tools.?;
    try std.testing.expectEqual(first.len, second.len);
    for (first, second) |was, now| try std.testing.expectEqualStrings(was.function.name, now.function.name);
    try std.testing.expect(!testing.declares(second, "double"));
}

test "a call of no tool, or of arguments that do not fit, is answered so, and the turn goes on" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: ai.testing.Fake = .init(arena, &.{
        try streamed(arena, &.{ call("c1", "nope", "{}"), call("c2", "add", "{\"a\":\"one\"}") }),
        try message(arena, "sorry"),
    });
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try openOver(&clock, .memory, &providers);
    defer siphon.close();
    try siphon.tools.add(add_tool);
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m" }, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, said("go"), "op-1");
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try expectEntries(siphon, arena, tid, &.{ "system", "input", "reply", "result unavailable", "result invalid-arguments", "reply", "turn-end" });
    // The model is told each as an error, the call it could not make in a note of Siphon's own.
    const outputs = fake.requests.items[1].input.?.parts;
    const missing = outputs[outputs.len - 2].function_call_output;
    try std.testing.expectEqualStrings("[no tool named nope]", missing.output.text);
    try std.testing.expect(missing.octoii.?.is_error.?);
    try std.testing.expect(outputs[outputs.len - 1].function_call_output.octoii.?.is_error.?);
}

test "a tool's output is told as its text, then each note on a line of its own in brackets" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("as it is", try tools.Tool.told(arena, .{ .text = "as it is" }));
    try std.testing.expectEqualStrings("a\nb\n[lines 1-2; more from offset 3]", try tools.Tool.told(arena, .{ .text = "a\nb\n", .notes = &.{"lines 1-2; more from offset 3"} }));
    try std.testing.expectEqualStrings("hi\n[exit 3]", try tools.Tool.told(arena, .{ .text = "hi", .notes = &.{"exit 3"} }));
    try std.testing.expectEqualStrings("[no match]\n[skipped 2 files, binary or too large]", try tools.Tool.told(arena, .{ .text = "", .notes = &.{ "no match", "skipped 2 files, binary or too large" } }));
}

test "the calls of one reply run at once, their results appended in the order the model made them" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The first lingers past the second, so the second ends first.
    var fake: ai.testing.Fake = .init(arena, &.{ try streamed(arena, &.{ call("c1", "meet", "{\"linger_ms\":200}"), call("c2", "meet", "{}") }), try message(arena, "met") });
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try openOver(&clock, .memory, &providers);
    defer siphon.close();
    var meeting: Meeting = .{ .expected = 2 };
    try siphon.tools.add(meeting.tool());
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m", .mode = .@"full-access" }, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, said("meet twice"), "op-1");
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try expectEntries(siphon, arena, tid, &.{ "system", "input", "reply", "result ok", "result ok", "reply", "turn-end" });
    const lines = try log.lines(siphon.runtime.volume, &arena, try threads.pathOf(arena, tid));
    try std.testing.expectEqualStrings("c1", (try foundation.json.decode(log.Result, arena, lines[3])).call_output.call_id);
    try std.testing.expectEqualStrings("c2", (try foundation.json.decode(log.Result, arena, lines[4])).call_output.call_id);
}

test "what the person sends while a call runs steers the turn: taken in after the call's result, the model asked on both" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: ai.testing.Fake = .init(arena, &.{ try streamed(arena, &.{call("c1", "meet", "{\"linger_ms\":300}")}), try message(arena, "met, and the rest") });
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try openOver(&clock, .memory, &providers);
    defer siphon.close();
    var meeting: Meeting = .{ .expected = 1 };
    try siphon.tools.add(meeting.tool());
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m", .mode = .@"full-access" }, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, said("meet once"), "op-1");
    try testing.pumpUntil(siphon, &meeting, Meeting.begun);
    _ = try threads.deliver(siphon.runtime, arena, tid, said("then meet the rest"), "op-2");
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    // One turn: the second input within it, after the result, before the reply it steered.
    try expectEntries(siphon, arena, tid, &.{ "system", "input", "reply", "result ok", "input", "reply", "turn-end" });
    try std.testing.expectEqual(@as(usize, 2), fake.requests.items.len);
    const asked = try foundation.json.encode(arena, fake.requests.items[1].input);
    try std.testing.expect(std.mem.indexOf(u8, asked, "then meet the rest") != null);
}

test "the effort the person sets is how a window is asked; one changed after its first reply is told where it stands" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: ai.testing.Fake = .init(arena, &.{ try message(arena, "one done"), try message(arena, "two done") });
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try openOver(&clock, .memory, &providers);
    defer siphon.close();
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m", .mode = .@"full-access" }, "create");
    try threads.configure(siphon.runtime, arena, tid, .{ .effort = .high });
    _ = try threads.deliver(siphon.runtime, arena, tid, said("one"), "op-1");
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try threads.configure(siphon.runtime, arena, tid, .{ .effort = .low });
    _ = try threads.deliver(siphon.runtime, arena, tid, said("two"), "op-2");
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try expectEntries(siphon, arena, tid, &.{ "system", "input", "configuration", "reply", "turn-end", "input", "configuration", "reply", "turn-end" });
    // The window was asked at the effort set before its first reply, both times; the change after it, where it stands.
    const first = fake.requests.items[0];
    const second = fake.requests.items[1];
    try std.testing.expectEqual(vocabulary.items.ReasoningEffort.high, first.reasoning.?.effort.?);
    try std.testing.expectEqual(vocabulary.items.ReasoningEffort.high, second.reasoning.?.effort.?);
    try std.testing.expect(std.mem.indexOf(u8, try foundation.json.encode(arena, first.input), "configuration_update") == null);
    try std.testing.expect(std.mem.indexOf(u8, try foundation.json.encode(arena, second.input), "{\"type\":\"configuration_update\",\"reasoning\":{\"effort\":\"low\"}}") != null);
}

test "a thread begun with no title is given the one its model writes on what the person asked; one given first is kept" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The turn's request and the title's go at once, so either may take either answer.
    var fake: ai.testing.Fake = .init(arena, &.{ try message(arena, "\"Fix the build.\""), try message(arena, "\"Fix the build.\"") });
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try openOver(&clock, .memory, &providers);
    defer siphon.close();
    const tid = try threads.create(siphon.runtime, arena, .{ .model = "fake/m", .mode = .@"full-access" }, "create");
    const thread = try threads.pathOf(arena, tid);
    _ = try threads.deliver(siphon.runtime, arena, tid, said("the build fails, fix it"), "op-1");
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    const Titled = struct {
        siphon: *Siphon,
        arena: Allocator,
        thread: []const u8,
        fn check(titled: *const @This()) bool {
            const manifest = threads.manifestOf(titled.siphon.runtime.volume, &titled.arena, titled.thread) catch return false;
            return manifest.title != null;
        }
    };
    try testing.pumpUntil(siphon, &Titled{ .siphon = siphon, .arena = arena, .thread = thread }, Titled.check);
    try std.testing.expectEqualStrings("Fix the build", (try threads.manifestOf(siphon.runtime.volume, &arena, thread)).title.?);
    // The title is asked on the turn's window, after the person's words.
    try std.testing.expectEqual(@as(usize, 2), fake.requests.items.len);
    const asked = try std.mem.concat(arena, u8, &.{ try foundation.json.encode(arena, fake.requests.items[0].input), try foundation.json.encode(arena, fake.requests.items[1].input) });
    try std.testing.expect(std.mem.indexOf(u8, asked, "Write a title for this thread") != null);
    // Its log holds the turn alone: the title is the thread's, not the conversation's.
    try expectEntries(siphon, arena, tid, &.{ "system", "input", "reply", "turn-end" });
}

test "a model that searches the web itself is given its provider's search; one changed to that does not, none" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var searching = model;
    searching.id = "s";
    searching.octoii.hosted_tools = &.{.web_search};
    var fake: ai.testing.Fake = .init(arena, &.{ try message(arena, "searched"), try message(arena, "plain") });
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ ai.facts.asFacts(searching), ai.facts.asFacts(model) } }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try openOver(&clock, .memory, &providers);
    defer siphon.close();
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/s", .mode = .@"full-access" }, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, said("what is new in zig 0.17"), "op-1");
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try threads.configure(siphon.runtime, arena, tid, .{ .model = "fake/m" });
    _ = try threads.deliver(siphon.runtime, arena, tid, said("and again"), "op-2");
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    const declares = struct {
        fn search(request: vocabulary.ResponsesRequest) bool {
            for (request.tools orelse &.{}) |tool| if (tool == .web_search) return true;
            return false;
        }
    };
    try std.testing.expect(declares.search(fake.requests.items[0]));
    try std.testing.expect(!declares.search(fake.requests.items[1]));
}

test "a task delegated is done by a sub-thread of the thread's, its last words the call's answer; a sub-thread delegates no further" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: ai.testing.Fake = .init(arena, &.{
        try streamed(arena, &.{call("c1", "delegate", "{\"task\":\"Check that the docs build.\",\"title\":\"Docs\"}")}),
        try message(arena, "The docs build."),
        try message(arena, "Done: the docs build."),
    });
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try openOver(&clock, .memory, &providers);
    defer siphon.close();
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m", .mode = .@"full-access", .effort = .low }, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, said("have a sub-agent check the docs"), "op-1");
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try expectEntries(siphon, arena, tid, &.{ "system", "input", "configuration", "reply", "result ok", "reply", "turn-end" });
    const lines = try log.lines(siphon.runtime.volume, &arena, try threads.pathOf(arena, tid));
    const result = try foundation.json.decode(log.Result, arena, lines[4]);
    try std.testing.expect(std.mem.indexOf(u8, try foundation.json.encode(arena, result.call_output), "The docs build.") != null);
    // The sub-thread: the thread's own, in its manifest, its parent the call; its work in its own log.
    const sub = (try threads.listedOf(siphon.runtime, arena, (try subThreadsOf(siphon, arena, tid))[0])).?;
    try std.testing.expectEqualStrings(tid, sub.manifest.parent.?.thread);
    try std.testing.expectEqualStrings("Docs", sub.manifest.title.?);
    try std.testing.expectEqual(threads.Mode.@"full-access", sub.manifest.mode);
    try std.testing.expectEqualStrings(result.call.?, sub.manifest.parent.?.call);
    try expectEntries(siphon, arena, sub.id, &.{ "system", "input", "configuration", "reply", "turn-end" });
    // The sub-thread's model is offered no delegate.
    const offered = try foundation.json.encode(arena, fake.requests.items[1].tools);
    try std.testing.expect(std.mem.indexOf(u8, offered, "\"delegate\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, try foundation.json.encode(arena, fake.requests.items[0].tools), "\"delegate\"") != null);
}

test "a thread stopped while its sub-thread works stops the sub-thread with it" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: ai.testing.Fake = .init(arena, &.{
        try streamed(arena, &.{call("c1", "delegate", "{\"task\":\"Deploy it.\",\"title\":\"Deploy\"}")}),
        try streamed(arena, &.{call("c2", "deploy", "{}")}),
    });
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try openOver(&clock, .memory, &providers);
    defer siphon.close();
    var slow: Slow = .{};
    try siphon.tools.add(slow.tool());
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m", .mode = .@"full-access" }, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, said("have a sub-agent deploy"), "op-1");
    try testing.pumpUntil(siphon, &slow, Slow.hasBegun);
    try threads.stop(siphon.runtime, arena, tid, "person");
    try std.testing.expectEqual(threads.Status.stopped, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try expectEntries(siphon, arena, tid, &.{ "system", "input", "reply", "result stopped", "turn-end" });
    const child = (try subThreadsOf(siphon, arena, tid))[0];
    try std.testing.expectEqual(threads.Status.stopped, (try testing.pumpUntilSettled(siphon, arena, child)).status);
}

test "a task delegated in the background is answered at once, and what came of it told the thread as its sub-thread finishes; the sub-thread goes with its thread" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: ai.testing.Fake = .init(arena, &.{
        try streamed(arena, &.{call("c1", "delegate", "{\"task\":\"Check that the docs build.\",\"title\":\"Docs\",\"background\":true}")}),
        // The thread's reply after the call and the sub-thread's reply are asked at once, in either order: they are one.
        try message(arena, "Noted."),
        try message(arena, "Noted."),
        try message(arena, "The docs build, it says."),
    });
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try openOver(&clock, .memory, &providers);
    defer siphon.close();
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m", .mode = .@"full-access" }, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, said("have a sub-agent check the docs in the background"), "op-1");
    try pumpUntilTurnsEnded(siphon, arena, tid, 2);
    try expectEntries(siphon, arena, tid, &.{ "system", "input", "reply", "result ok", "reply", "turn-end", "input", "reply", "turn-end" });
    const child = (try subThreadsOf(siphon, arena, tid))[0];
    const lines = try log.lines(siphon.runtime.volume, &arena, try threads.pathOf(arena, tid));
    // The call is answered at once, where the sub-thread works on.
    const answered = try foundation.json.encode(arena, (try foundation.json.decode(log.Result, arena, lines[3])).call_output);
    try std.testing.expect(std.mem.indexOf(u8, answered, "works on it in the background") != null);
    // What came of it is a turn's input, the sub-thread's, its last words after Siphon's note.
    const notice = try foundation.json.decode(log.Input, arena, lines[6]);
    try std.testing.expectEqualStrings(try threads.actorOf(arena, child), notice.actor);
    const parts = notice.message.content.parts;
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    try std.testing.expect(std.mem.startsWith(u8, parts[0].input_text.text, try std.fmt.allocPrint(arena, "[the sub-thread {s}, which you gave a task in the background, finished", .{child})));
    try std.testing.expectEqualStrings("Noted.", parts[1].input_text.text);
    // The sub-thread's task is the thread's.
    try expectEntries(siphon, arena, child, &.{ "system", "input", "reply", "turn-end" });
    const task = try foundation.json.decode(log.Input, arena, (try log.lines(siphon.runtime.volume, &arena, try threads.pathOf(arena, child)))[1]);
    try std.testing.expectEqualStrings(try threads.actorOf(arena, tid), task.actor);
    // Deleted, the thread takes its sub-threads with it.
    const gone = try threads.delete(siphon.runtime, arena, tid);
    try std.testing.expectEqual(@as(usize, 2), gone.len);
    for (0..20) |_| _ = try siphon.runtime.pump();
    try std.testing.expect(try siphon.runtime.volume.stat(&arena, try threads.pathOf(arena, child)) == null);
}

test "a sub-thread of the thread's is given more to do by its id, keeping what it did; a thread no sub-thread of its is refused" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const first = [_]ai.testing.fake.Answer{
        try streamed(arena, &.{call("c1", "delegate", "{\"task\":\"Check that the docs build.\",\"title\":\"Docs\"}")}),
        try message(arena, "The docs build."),
        try message(arena, "Done."),
    };
    var fake: ai.testing.Fake = .init(arena, &first);
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try openOver(&clock, .memory, &providers);
    defer siphon.close();
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m", .mode = .@"full-access" }, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, said("have a sub-agent check the docs"), "op-1");
    _ = try testing.pumpUntilSettled(siphon, arena, tid);
    const child = (try subThreadsOf(siphon, arena, tid))[0];
    // The model names the sub-thread it was told of, and the thread itself, which is none of its sub-threads.
    fake.answers = try std.mem.concat(arena, ai.testing.fake.Answer, &.{ &first, &.{
        try streamed(arena, &.{
            call("c2", "delegate", try std.fmt.allocPrint(arena, "{{\"thread\":\"{s}\",\"task\":\"Also check the links.\"}}", .{child})),
            call("c3", "delegate", try std.fmt.allocPrint(arena, "{{\"thread\":\"{s}\",\"task\":\"Check it all.\"}}", .{tid})),
        }),
        try message(arena, "The links hold."),
        try message(arena, "Both hold."),
    } });
    _ = try threads.deliver(siphon.runtime, arena, tid, said("and have it check the links"), "op-2");
    try pumpUntilTurnsEnded(siphon, arena, tid, 2);
    try expectEntries(siphon, arena, tid, &.{ "system", "input", "reply", "result ok", "reply", "turn-end", "input", "reply", "result ok", "result tool-error", "reply", "turn-end" });
    const lines = try log.lines(siphon.runtime.volume, &arena, try threads.pathOf(arena, tid));
    const followed = try foundation.json.encode(arena, (try foundation.json.decode(log.Result, arena, lines[8])).call_output);
    try std.testing.expect(std.mem.indexOf(u8, followed, "The links hold.") != null);
    try std.testing.expect(std.mem.indexOf(u8, followed, "The docs build.") == null);
    const refused = try foundation.json.encode(arena, (try foundation.json.decode(log.Result, arena, lines[9])).call_output);
    try std.testing.expect(std.mem.indexOf(u8, refused, "is no sub-thread of yours") != null);
    // The sub-thread took the task as a turn of its own, on what it did before.
    try expectEntries(siphon, arena, child, &.{ "system", "input", "reply", "turn-end", "input", "reply", "turn-end" });
    try std.testing.expect(std.mem.indexOf(u8, try foundation.json.encode(arena, fake.requests.items[4].input), "The docs build.") != null);
}

test "a stop reaches every call that runs, answers each stopped, and the turn ends stopped" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: ai.testing.Fake = .init(arena, &.{try streamed(arena, &.{ call("c1", "deploy", "{}"), call("c2", "deploy", "{}") })});
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try openOver(&clock, .memory, &providers);
    defer siphon.close();
    var slow: Slow = .{};
    try siphon.tools.add(slow.tool());
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m", .mode = .@"full-access" }, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, said("deploy twice"), "op-1");
    try testing.pumpUntil(siphon, &slow, Slow.bothBegun);
    try threads.stop(siphon.runtime, arena, tid, "person");
    try std.testing.expectEqual(threads.Status.stopped, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try expectEntries(siphon, arena, tid, &.{ "system", "input", "reply", "result stopped", "result stopped", "turn-end" });
}

test "a thread's state shows each request its fibers wait on, as it was made, by the turn and the call it is of" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: ai.testing.Fake = .init(arena, &.{try streamed(arena, &.{call("c1", "deploy", "{}")})});
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try openOver(&clock, .memory, &providers);
    defer siphon.close();
    var slow: Slow = .{};
    try siphon.tools.add(slow.tool());
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m", .mode = .@"full-access" }, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, said("deploy"), "op-1");
    try testing.pumpUntil(siphon, &slow, Slow.hasBegun);

    // The call runs: the thread's fibers as processes, each under its parent — the main fiber, the turn, the call, with
    // the call as the model made it, by the provider's id, and its tool's request waiting as the call's fiber made it.
    const running = try threads.state(siphon.runtime, arena, tid);
    try std.testing.expectEqual(threads.Status.running, running.status);
    const fibers = running.processes;
    try std.testing.expectEqual(@as(usize, 3), fibers.len);
    try std.testing.expectEqualStrings("main", fibers[0].key);
    const turn = fibers[1];
    try std.testing.expectEqualStrings(threads.turn_program, turn.program);
    try std.testing.expectEqualStrings("main", turn.parent.?);
    const runs = fibers[2];
    try std.testing.expectEqualStrings(calls.call_program, runs.program);
    try std.testing.expectEqualStrings(turn.key, runs.parent.?);
    try std.testing.expectEqualStrings("c1", (try foundation.json.decode(calls.Input, arena, runs.input.?.text)).call_id);
    try std.testing.expectEqual(@as(usize, 1), runs.requests.len);
    try std.testing.expectEqualStrings(tools.Tool.request_name, runs.requests[0].name);
    const asked = try foundation.json.decode(tools.Tool.Call, arena, runs.requests[0].payload.?.text);
    try std.testing.expectEqualStrings("deploy", asked.name);

    // Stopped, it is answered, and what came of each part names it: the call's result its call, the end its turn.
    try threads.stop(siphon.runtime, arena, tid, "person");
    const settled = try testing.pumpUntilSettled(siphon, arena, tid);
    try std.testing.expectEqual(@as(usize, 1), settled.processes.len);
    try std.testing.expectEqual(@as(usize, 0), settled.processes[0].requests.len);
    try expectEntries(siphon, arena, tid, &.{ "system", "input", "reply", "result stopped", "turn-end" });
    const lines = try log.lines(siphon.runtime.volume, &arena, try threads.pathOf(arena, tid));
    try std.testing.expectEqualStrings(runs.key, (try foundation.json.decode(log.Result, arena, lines[3])).call.?);
    try std.testing.expectEqualStrings(turn.key, (try foundation.json.decode(log.TurnEnd, arena, lines[4])).turn.?);
}

test "a call that may have acted, cut off as the host ends, is answered interrupted and never run again" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const place = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path, "volume" });
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    var tid: []const u8 = undefined;
    {
        var fake: ai.testing.Fake = .init(arena, &.{try streamed(arena, &.{call("c1", "deploy", "{}")})});
        const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(model)} }};
        const siphon = try openOver(&clock, .{ .directory = place }, &providers);
        defer siphon.close();
        var slow: Slow = .{};
        try siphon.tools.add(slow.tool());
        tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m", .mode = .@"full-access" }, "create");
        _ = try threads.deliver(siphon.runtime, arena, tid, said("deploy"), "op-1");
        try testing.pumpUntil(siphon, &slow, Slow.hasBegun);
    }
    clock.now_ms += 1_000;
    var fake: ai.testing.Fake = .init(arena, &.{try message(arena, "it may have gone out")});
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(model)} }};
    const siphon = try openOver(&clock, .{ .directory = place }, &providers);
    defer siphon.close();
    var again: Slow = .{};
    try siphon.tools.add(again.tool());
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try expectEntries(siphon, arena, tid, &.{ "system", "input", "reply", "result interrupted", "reply", "turn-end" });
    try std.testing.expectEqual(@as(u32, 0), again.began.load(.monotonic));
}
