//! Threads on a fake host: inputs delivered once, taken into the log by the thread's fiber, turns that ask a model and
//! append its reply, settled with their ends — stopped, failed, and asked again when the volume opens again.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const Siphon = @import("Siphon.zig");
const Request = @import("runtime.zig").Request;
const threads = @import("threads.zig");
const models = @import("agent.zig").models;
const log = @import("threads.zig").log;
const testing = @import("testing.zig");

/// A model that answers from a script: a text, a failure, or a wait until a stop, answered with what had come.
const FakeModel = struct {
    behavior: enum { answer, fail, slow } = .answer,
    /// What each answer says its request used, as JSON; none, nothing.
    usage: ?[]const u8 = null,
    began: std.atomic.Value(bool) = .init(false),
    asked: std.atomic.Value(u32) = .init(0),

    fn act(context: ?*anyopaque, request: *Request) anyerror!void {
        const model: *FakeModel = @ptrCast(@alignCast(context.?));
        _ = model.asked.fetchAdd(1, .monotonic);
        const arena = request.arena();
        const asked = try foundation.json.decode(models.ModelRequest, arena, request.payload);
        // It reads the log up to the entry its request names, as a rendering does.
        const lines = try log.lines(request.runtime.volume, &arena, try threads.pathOf(arena, asked.thread));
        if (!std.mem.eql(u8, (try log.headOf(arena, lines[lines.len - 1])).id, asked.until)) return error.LogMoved;
        switch (model.behavior) {
            .answer => return request.answer(foundation.json.Raw{ .text = try responseUsing(arena, "Hi", model.usage) }),
            .fail => return error.ModelDown,
            .slow => {
                model.began.store(true, .release);
                request.runtime.host.io.sleep(.fromSeconds(3600), .awake) catch |err| switch (err) {
                    error.Canceled => return request.answer(foundation.json.Raw{ .text = try responseOf(arena, "partial") }),
                };
                return request.answer(foundation.json.Raw{ .text = try responseOf(arena, "Hi") });
            },
        }
    }

    fn hasBegun(model: *FakeModel) bool {
        return model.began.load(.acquire);
    }

    fn handler(model: *FakeModel) Request.Handler {
        return .{ .context = model, .act = act };
    }
};

fn responseOf(arena: Allocator, text: []const u8) ![]const u8 {
    return responseUsing(arena, text, null);
}

/// A response of `text`, saying its request used `usage`, where given.
fn responseUsing(arena: Allocator, text: []const u8, usage: ?[]const u8) ![]const u8 {
    const used = if (usage) |given| try std.fmt.allocPrint(arena, ",\"usage\":{s}", .{given}) else "";
    return std.fmt.allocPrint(arena, "{{\"id\":\"r1\",\"status\":\"completed\",\"output\":[{{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{{\"type\":\"output_text\",\"text\":\"{s}\"}}]}}]{s}}}", .{ text, used });
}

const said = testing.said;

fn expectTypes(siphon: *Siphon, arena: *const Allocator, tid: []const u8, expected: []const []const u8) !void {
    const lines = try log.lines(siphon.runtime.volume, arena, try threads.pathOf(arena.*, tid));
    try std.testing.expectEqual(expected.len, lines.len);
    for (expected, lines) |want, line| try std.testing.expectEqualStrings(want, (try log.headOf(arena.*, line)).type);
}

test "an input is delivered once for its operation, taken into the log, and answered by a turn its thread settles" {
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.open(&clock, .memory);
    defer siphon.close();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var model: FakeModel = .{};
    try siphon.runtime.handle(models.model_request, model.handler());
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/model" }, "create");
    const first = try threads.deliver(siphon.runtime, arena, tid, said("hello"), "op-1");
    try std.testing.expectEqualStrings(first, try threads.deliver(siphon.runtime, arena, tid, said("hello"), "op-1"));
    const queued = (try threads.state(siphon.runtime, arena, tid)).inbox;
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    try std.testing.expectEqualStrings(first, queued[0].id);
    try std.testing.expectEqualStrings("person", queued[0].actor);
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try expectTypes(siphon, &arena, tid, &.{ "system", "input", "reply", "turn-end" });
    try std.testing.expectEqual(@as(u32, 1), model.asked.load(.monotonic));

    // The next input starts the next turn, after the one before ended.
    _ = try threads.deliver(siphon.runtime, arena, tid, said("again"), "op-2");
    _ = try testing.pumpUntilSettled(siphon, arena, tid);
    try expectTypes(siphon, &arena, tid, &.{ "system", "input", "reply", "turn-end", "input", "reply", "turn-end" });
}

test "the inputs waiting as a turn starts are taken into one segment of the log, in the order they came" {
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.open(&clock, .memory);
    defer siphon.close();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var model: FakeModel = .{};
    try siphon.runtime.handle(models.model_request, model.handler());
    const tid = try threads.create(siphon.runtime, arena, .{}, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, said("one"), "op-1");
    _ = try threads.deliver(siphon.runtime, arena, tid, said("two"), "op-2");
    const waiting = try threads.state(siphon.runtime, arena, tid);
    try std.testing.expectEqual(threads.Status.created, waiting.status);
    try std.testing.expectEqual(@as(usize, 2), waiting.inbox.len);
    // No turn runs: the thread's main fiber alone.
    try std.testing.expectEqual(@as(usize, 1), waiting.processes.len);
    try std.testing.expectEqualStrings("main", waiting.processes[0].key);
    try std.testing.expect(waiting.processes[0].parent == null);
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try expectTypes(siphon, &arena, tid, &.{ "system", "input", "input", "reply", "turn-end" });
    try std.testing.expectEqual(@as(usize, 1), (try log.segments(siphon.runtime.volume, &arena, try threads.pathOf(arena, tid))).len);
}

test "a thread is made once for its operation's id, and an id names one operation alone" {
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.open(&clock, .memory);
    defer siphon.close();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tid = try threads.create(siphon.runtime, arena, .{}, "op-a");
    try std.testing.expectEqualStrings(tid, try threads.create(siphon.runtime, arena, .{}, "op-a"));
    // The id of one operation sent for another method, or for another thread, is refused.
    try std.testing.expectError(error.OperationReused, threads.deliver(siphon.runtime, arena, tid, said("hi"), "op-a"));
    const other = try threads.create(siphon.runtime, arena, .{}, "op-b");
    _ = try threads.deliver(siphon.runtime, arena, tid, said("hi"), "op-c");
    try std.testing.expectError(error.OperationReused, threads.deliver(siphon.runtime, arena, other, said("hi"), "op-c"));
    try std.testing.expectError(error.InvalidOperation, threads.create(siphon.runtime, arena, .{}, "a/b"));
    try std.testing.expectEqual(@as(usize, 2), (try siphon.runtime.volume.list(&arena, "", threads.kind ++ ":")).len);
}

test "a thread's model, title, mode and how the person keeps it are changed as they change them, each left out kept" {
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.open(&clock, .memory);
    defer siphon.close();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/model", .workspace = "/w" }, "create");
    const thread = try threads.pathOf(arena, tid);
    try threads.configure(siphon.runtime, arena, tid, .{ .title = "Named" });
    try threads.configure(siphon.runtime, arena, tid, .{ .model = "fake/other" });
    try std.testing.expectEqual(threads.Mode.default, (try threads.manifestOf(siphon.runtime.volume, &arena, thread)).mode);
    try threads.configure(siphon.runtime, arena, tid, .{ .mode = .auto });
    const manifest = try threads.manifestOf(siphon.runtime.volume, &arena, thread);
    try std.testing.expectEqual(threads.Mode.auto, manifest.mode);
    try std.testing.expectEqualStrings("Named", manifest.title.?);
    try std.testing.expectEqualStrings("fake/other", manifest.model.?);
    try std.testing.expectEqualStrings("/w", manifest.workspace.?);
    // How the person keeps it: pinned, archived, snoozed — each changed alone, the rest kept.
    try threads.configure(siphon.runtime, arena, tid, .{ .pinned = true, .snoozed_until = 5_000 });
    try threads.configure(siphon.runtime, arena, tid, .{ .archived = true });
    const kept = try threads.manifestOf(siphon.runtime.volume, &arena, thread);
    try std.testing.expect(kept.pinned and kept.archived);
    try std.testing.expectEqual(@as(?i64, 5_000), kept.snoozed_until);
    try std.testing.expectEqualStrings("Named", kept.title.?);
    try std.testing.expectError(error.NoSuchThread, threads.configure(siphon.runtime, arena, "01990000-0000-7000-8000-000000000000", .{ .title = "x" }));
}

test "an input withdrawn while it waits is never taken; one taken can no longer be" {
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.open(&clock, .memory);
    defer siphon.close();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var model: FakeModel = .{};
    try siphon.runtime.handle(models.model_request, model.handler());
    const tid = try threads.create(siphon.runtime, arena, .{}, "create");
    const withdrawn = try threads.deliver(siphon.runtime, arena, tid, said("never mind"), "op-1");
    try std.testing.expect(try threads.withdraw(siphon.runtime, arena, tid, withdrawn));
    for (0..3) |_| _ = try siphon.runtime.pump();
    try expectTypes(siphon, &arena, tid, &.{});
    const taken = try threads.deliver(siphon.runtime, arena, tid, said("hello"), "op-2");
    _ = try testing.pumpUntilSettled(siphon, arena, tid);
    try std.testing.expect(!try threads.withdraw(siphon.runtime, arena, tid, taken));
}

test "a thread's state holds when its latest turn began and ended: none before its first, no end while it runs" {
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.open(&clock, .memory);
    defer siphon.close();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var model: FakeModel = .{};
    try siphon.runtime.handle(models.model_request, model.handler());
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test" }, "create");
    const made = try threads.state(siphon.runtime, arena, tid);
    try std.testing.expectEqual(@as(?i64, null), made.began_at);
    try std.testing.expectEqual(@as(?i64, null), made.ended_at);
    _ = try threads.deliver(siphon.runtime, arena, tid, said("hello"), "op-1");
    clock.now_ms = 2_000;
    const first = try testing.pumpUntilSettled(siphon, arena, tid);
    try std.testing.expectEqual(@as(?i64, 2_000), first.began_at);
    try std.testing.expectEqual(@as(?i64, 2_000), first.ended_at);
    // A turn that runs has begun, and its end is not the last one's.
    model.behavior = .slow;
    _ = try threads.deliver(siphon.runtime, arena, tid, said("and again"), "op-2");
    clock.now_ms = 5_000;
    try testing.pumpUntil(siphon, &model, FakeModel.hasBegun);
    const running = try threads.state(siphon.runtime, arena, tid);
    try std.testing.expectEqual(threads.Status.running, running.status);
    try std.testing.expectEqual(@as(?i64, 5_000), running.began_at);
    try std.testing.expectEqual(@as(?i64, null), running.ended_at);
    clock.now_ms = 9_000;
    try threads.stop(siphon.runtime, arena, tid, "person");
    const stopped = try testing.pumpUntilSettled(siphon, arena, tid);
    try std.testing.expectEqual(threads.Status.stopped, stopped.status);
    try std.testing.expectEqual(@as(?i64, 5_000), stopped.began_at);
    try std.testing.expectEqual(@as(?i64, 9_000), stopped.ended_at);
}

test "a thread's state holds what its model requests used, each charged to its turn and to the main fiber above it" {
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.open(&clock, .memory);
    defer siphon.close();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var model: FakeModel = .{ .usage =
        \\{"input_tokens":100,"input_tokens_details":{"cached_tokens":40},"output_tokens":20,"output_tokens_details":{"reasoning_tokens":5},"total_tokens":120,"cost":0.0002}
    };
    try siphon.runtime.handle(models.model_request, model.handler());
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test" }, "create");
    try std.testing.expectEqual(@as(?threads.Usage, null), (try threads.state(siphon.runtime, arena, tid)).usage);
    _ = try threads.deliver(siphon.runtime, arena, tid, said("hello"), "op-1");
    _ = try testing.pumpUntilSettled(siphon, arena, tid);
    _ = try threads.deliver(siphon.runtime, arena, tid, said("and again"), "op-2");
    const settled = try testing.pumpUntilSettled(siphon, arena, tid);
    // The turns are reaped; what they used stays the thread's, as a cgroup keeps what its ended tasks used.
    try std.testing.expectEqualDeep(@as(?threads.Usage, .{ .input_tokens = 200, .cached_tokens = 80, .output_tokens = 40, .reasoning_tokens = 10, .cost_nanodollars = 400_000 }), settled.usage);
}

test "a thread deleted while its model answers is gone, its request cut off, and nothing of it left" {
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.open(&clock, .memory);
    defer siphon.close();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var model: FakeModel = .{ .behavior = .slow };
    try siphon.runtime.handle(models.model_request, model.handler());
    const tid = try threads.create(siphon.runtime, arena, .{}, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, said("write a long story"), "op-1");
    try testing.pumpUntil(siphon, &model, FakeModel.hasBegun);
    _ = try threads.delete(siphon.runtime, arena, tid);
    for (0..20) |_| _ = try siphon.runtime.pump();
    try std.testing.expect(try siphon.runtime.volume.stat(&arena, try threads.pathOf(arena, tid)) == null);
    try std.testing.expectError(error.NoSuchThread, threads.delete(siphon.runtime, arena, tid));
}

test "a stop ends the turn at once, keeping what had come of its reply as cut" {
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.open(&clock, .memory);
    defer siphon.close();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var model: FakeModel = .{ .behavior = .slow };
    try siphon.runtime.handle(models.model_request, model.handler());
    const tid = try threads.create(siphon.runtime, arena, .{}, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, said("write a long story"), "op-1");
    try testing.pumpUntil(siphon, &model, FakeModel.hasBegun);
    try threads.stop(siphon.runtime, arena, tid, "person");
    try std.testing.expectEqual(threads.Status.stopped, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try expectTypes(siphon, &arena, tid, &.{ "system", "input", "reply", "turn-end" });
    const lines = try log.lines(siphon.runtime.volume, &arena, try threads.pathOf(arena, tid));
    const reply = try foundation.json.decode(log.Reply, arena, lines[2]);
    try std.testing.expect(reply.cancelled.?);
    try std.testing.expect(std.mem.indexOf(u8, reply.response.text, "partial") != null);
}

test "a turn whose model fails ends failed, and holds nothing back: the next input starts the next turn" {
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.open(&clock, .memory);
    defer siphon.close();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var model: FakeModel = .{ .behavior = .fail };
    try siphon.runtime.handle(models.model_request, model.handler());
    const tid = try threads.create(siphon.runtime, arena, .{}, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, said("hello"), "op-1");
    try std.testing.expectEqual(threads.Status.failed, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    model.behavior = .answer;
    _ = try threads.deliver(siphon.runtime, arena, tid, said("again"), "op-2");
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try expectTypes(siphon, &arena, tid, &.{ "system", "input", "turn-end", "input", "reply", "turn-end" });
}

test "a model's request cut off as the volume opens again is asked again, as it was" {
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const place = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path, "volume" });
    var tid: []const u8 = undefined;
    {
        // The model is slow to answer: its request waits as the host ends.
        const siphon = try testing.open(&clock, .{ .directory = place });
        defer siphon.close();
        var slow: FakeModel = .{ .behavior = .slow };
        try siphon.runtime.handle(models.model_request, slow.handler());
        tid = try threads.create(siphon.runtime, arena, .{}, "create");
        _ = try threads.deliver(siphon.runtime, arena, tid, said("hello"), "op-1");
        try testing.pumpUntilStatus(siphon, arena, tid, .running);
    }
    clock.now_ms += 1_000;
    const siphon = try testing.open(&clock, .{ .directory = place });
    defer siphon.close();
    var model: FakeModel = .{};
    try siphon.runtime.handle(models.model_request, model.handler());
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try expectTypes(siphon, &arena, tid, &.{ "system", "input", "reply", "turn-end" });
    try std.testing.expectEqual(@as(u32, 1), model.asked.load(.monotonic));
}
