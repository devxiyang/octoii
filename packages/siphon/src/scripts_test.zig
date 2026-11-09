//! Scripts, as the model runs them by `execute` over a fake provider: their calls made at once and in turn, each made
//! and settled in the thread's log under the script's call, what they wrote and returned told as the call's result,
//! the model never sent its script's results; a call its tool could not do thrown into the script, and what the script
//! throws its call's error; a script cut off by the host's end going on from its log, its settled calls never made
//! again; a stop ending a script and the calls it made, each settled as it ended; and a script's step as its thread's
//! state shows it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const typebox = @import("typebox");
const vocabulary = @import("vocabulary");
const ai = @import("ai");
const Siphon = @import("Siphon.zig");
const threads = @import("threads.zig");
const testing = @import("testing.zig");
const tools = @import("tools.zig");
const scripts = @import("tools.zig").scripts;

const streamed = testing.streamed;
const message = testing.message;
const call = testing.call;
const said = testing.said;

/// Adds two numbers, counting how often it was asked: read-only.
const Adder = struct {
    asked: std.atomic.Value(u32) = .init(0),

    const Numbers = struct { a: f64, b: f64 };

    fn tool(adder: *Adder) @import("tools.zig").Tool {
        return .{ .name = "add", .description = "Adds two numbers.", .parameters = typebox.of(Numbers), .context = adder, .work = .{ .task = run } };
    }

    fn run(context: ?*anyopaque, given: *const tools.Tool.Run) anyerror!tools.Tool.Output {
        const adder: *Adder = @ptrCast(@alignCast(context.?));
        _ = adder.asked.fetchAdd(1, .monotonic);
        const numbers = try foundation.json.decode(Numbers, given.arena, given.arguments);
        return .{ .text = try given.arena.print("{d}", .{numbers.a + numbers.b}) };
    }
};

const executing = testing.executing;
const toldOutputs = testing.toldOutputs;

test "a script calls its tools at once and in turn, each made and settled under its call, and its call's result is what it wrote, then what it returned" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const code =
        \\const [a, b] = await Promise.all([tools.add({ a: 1, b: 2 }), tools.add({ a: 3, b: 4 })]);
        \\console.log("sums", a, b);
        \\const total: string = await tools.add({ a: Number(a), b: Number(b) });
        \\return { total: Number(total) };
    ;
    var fake: ai.testing.Fake = .init(arena, &.{ try streamed(arena, &.{try executing(arena, "c1", code)}), try message(arena, "10") });
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(testing.model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.openOver(&clock, .memory, &providers);
    defer siphon.close();
    var adder: Adder = .{};
    try siphon.tools.add(adder.tool());
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m" }, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, said("add them up"), "op-1");
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try testing.expectEntries(siphon, arena, tid, &.{
        "system",             "input",              "reply",     "calls add add under c1", "result ok under c1", "result ok under c1",
        "calls add under c1", "result ok under c1", "result ok", "reply",                  "turn-end",
    });
    // The model is told what its script wrote and returned, and nothing of the results the script read.
    const outputs = try toldOutputs(&fake, arena, 1);
    try std.testing.expectEqual(@as(usize, 1), outputs.len);
    try std.testing.expectEqualStrings("sums 3 7\n{\"total\":10}", outputs[0]);
    try std.testing.expectEqual(@as(u32, 3), adder.asked.load(.monotonic));
    // The model is told of `execute` beside the tools its scripts call.
    try std.testing.expect(testing.declares(fake.requests.items[0].tools.?, "execute"));
}

test "a call its tool could not do is thrown into the script, and what the script throws is its call's error" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const refusing =
        \\try {
        \\  await tools.add({ a: "one" });
        \\} catch (e) {
        \\  console.log("refused:", e.message);
        \\}
        \\throw new TypeError("the sum is wrong");
    ;
    var fake: ai.testing.Fake = .init(arena, &.{
        try streamed(arena, &.{ try executing(arena, "c1", refusing), try executing(arena, "c2", "return (;") }),
        try message(arena, "sorry"),
    });
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(testing.model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.openOver(&clock, .memory, &providers);
    defer siphon.close();
    var adder: Adder = .{};
    try siphon.tools.add(adder.tool());
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m" }, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, said("add one"), "op-1");
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try testing.expectEntries(siphon, arena, tid, &.{ "system", "input", "reply", "calls add under c1", "result invalid-arguments under c1", "result tool-error", "result tool-error", "reply", "turn-end" });
    const outputs = try toldOutputs(&fake, arena, 1);
    // The arguments that do not fit are refused before the tool runs, and the script reads why.
    const thrown = "refused: / must have required property 'b'; /a must be number\nTypeError: the sum is wrong\n";
    try std.testing.expectStringStartsWith(outputs[0], thrown);
    try std.testing.expect(std.mem.indexOf(u8, outputs[0][thrown.len..], "script.ts:6:") != null);
    try std.testing.expectEqual(@as(u32, 0), adder.asked.load(.monotonic));
    try std.testing.expectStringStartsWith(outputs[1], "SyntaxError: ");
}

test "a script cut off by the host's end goes on from its log, the calls it settled never made again" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const place = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path, "volume" });
    const code =
        \\const sum = await tools.add({ a: 1, b: 2 });
        \\try {
        \\  await tools.deploy({});
        \\} catch (e) {
        \\  return `${sum}, then ${e.message}`;
        \\}
    ;
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    var tid: []const u8 = undefined;
    {
        var fake: ai.testing.Fake = .init(arena, &.{try streamed(arena, &.{try executing(arena, "c1", code)})});
        const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(testing.model)} }};
        const siphon = try testing.openOver(&clock, .{ .directory = place }, &providers);
        defer siphon.close();
        var adder: Adder = .{};
        try siphon.tools.add(adder.tool());
        var slow: testing.Slow = .{};
        try siphon.tools.add(slow.tool());
        tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m", .mode = .@"full-access" }, "create");
        _ = try threads.deliver(siphon.runtime, arena, tid, said("add, then deploy"), "op-1");
        try testing.pumpUntil(siphon, &slow, testing.Slow.hasBegun);
        try std.testing.expectEqual(@as(u32, 1), adder.asked.load(.monotonic));
    }
    clock.now_ms += 1_000;
    var fake: ai.testing.Fake = .init(arena, &.{try message(arena, "it may have gone out")});
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(testing.model)} }};
    const siphon = try testing.openOver(&clock, .{ .directory = place }, &providers);
    defer siphon.close();
    var adder: Adder = .{};
    try siphon.tools.add(adder.tool());
    var slow: testing.Slow = .{};
    try siphon.tools.add(slow.tool());
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try testing.expectEntries(siphon, arena, tid, &.{ "system", "input", "reply", "calls add under c1", "result ok under c1", "calls deploy under c1", "result interrupted under c1", "result ok", "reply", "turn-end" });
    // Replayed, the script was given the sum it had, and the deploy cut off was settled so, never run again.
    try std.testing.expectEqualStrings("\"3, then [cut off as it ran; it may or may not have acted]\"", (try toldOutputs(&fake, arena, 0))[0]);
    try std.testing.expectEqual(@as(u32, 0), adder.asked.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), slow.began.load(.monotonic));
}

test "a stop ends a script once the calls it made ended, each settled, its call stopped and the turn with it" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var fake: ai.testing.Fake = .init(arena, &.{try streamed(arena, &.{try executing(arena, "c1", "await Promise.all([tools.deploy({}), tools.deploy({})]);")})});
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(testing.model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.openOver(&clock, .memory, &providers);
    defer siphon.close();
    var slow: testing.Slow = .{};
    try siphon.tools.add(slow.tool());
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m", .mode = .@"full-access" }, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, said("deploy twice"), "op-1");
    try testing.pumpUntil(siphon, &slow, testing.Slow.bothBegun);
    try threads.stop(siphon.runtime, arena, tid, "person");
    const settled = try testing.pumpUntilSettled(siphon, arena, tid);
    try std.testing.expectEqual(threads.Status.stopped, settled.status);
    try testing.expectEntries(siphon, arena, tid, &.{ "system", "input", "reply", "calls deploy deploy under c1", "result stopped under c1", "result stopped under c1", "result stopped", "turn-end" });
    // Nothing of the script lives on: the thread's main fiber alone is left.
    try std.testing.expectEqual(@as(usize, 1), settled.processes.len);
}

/// Holds every request it acts on: none is answered till a stop cuts it off.
const Holding = struct {
    began: std.atomic.Value(u32) = .init(0),

    fn handler(holding: *Holding) @import("runtime.zig").Request.Handler {
        return .{ .context = holding, .act = act };
    }

    fn act(context: ?*anyopaque, request: *@import("runtime.zig").Request) anyerror!void {
        const holding: *Holding = @ptrCast(@alignCast(context.?));
        _ = holding.began.fetchAdd(1, .release);
        try request.runtime.host.io.sleep(.fromSeconds(3600), .awake);
    }

    fn hasBegun(holding: *Holding) bool {
        return holding.began.load(.acquire) > 0;
    }
};

test "a script's step shows in its thread's state as the request it is, which says no more than its name" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var fake: ai.testing.Fake = .init(arena, &.{try streamed(arena, &.{try executing(arena, "c1", "return 1;")})});
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(testing.model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.openOver(&clock, .memory, &providers);
    defer siphon.close();
    var holding: Holding = .{};
    try siphon.runtime.handle(scripts.step_request, holding.handler());
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m", .mode = .@"full-access" }, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, said("one"), "op-1");
    try testing.pumpUntil(siphon, &holding, Holding.hasBegun);

    const running = try threads.state(siphon.runtime, arena, tid);
    const script = for (running.processes) |process| {
        if (std.mem.eql(u8, process.program, scripts.script_program)) break process;
    } else return error.NoScript;
    try std.testing.expectEqual(@as(usize, 1), script.requests.len);
    try std.testing.expectEqualStrings(scripts.step_request, script.requests[0].name);
    try std.testing.expect(script.requests[0].payload == null);
    // The state is JSON as a client is told it.
    _ = try std.json.parseFromSliceLeaky(std.json.Value, arena, try foundation.json.encode(arena, running), .{});

    try threads.stop(siphon.runtime, arena, tid, "person");
    try std.testing.expectEqual(threads.Status.stopped, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
}
