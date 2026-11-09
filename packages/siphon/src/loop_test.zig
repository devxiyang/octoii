//! Siphon's loop on a fake host: fibers dispatched by Beak, the requests they make acted on as Beak tells of them, and
//! every request answered once — by its handler, for a handler that failed, at once under a stop, and interrupted when
//! the volume opens again.
const std = @import("std");
const foundation = @import("foundation");
const Siphon = @import("Siphon.zig");
const Phase = @import("runtime.zig").Phase;
const Request = @import("runtime.zig").Request;
const testing = @import("testing.zig");
const beak = @import("beak.zig");
const h = beak.h;

/// A fiber that asks one request, of the name its program is given, then ends with the answer's mail, its name and its
/// payload as they came. Its stop handler waits for the answer too, and ends stopped with it.
const Asker = struct {
    fn phase(context: ?*anyopaque, run: *Phase) anyerror!void {
        const name: *const []const u8 = @ptrCast(@alignCast(context.?));
        if (run.checkpoint.len == 0) {
            try run.request(name.*, "k1", "hello");
            return run.waitForMail("asked", "k1");
        }
        const answer = try run.mailOf("k1") orelse return run.waitForMail("asked", "k1");
        try run.take(answer.key);
        const result: Said = .{ .name = answer.name, .payload = answer.payload };
        return if (run.stop_handler) run.stopped(result) else run.done(result);
    }

    fn program(name: *const []const u8) @import("runtime.zig").Program {
        return .{ .kind = "test.asker", .stop_handler = true, .context = @ptrCast(@constCast(name)), .phase = phase };
    }
};

/// What an asker ended with: its answer's mail, by its name, and its payload as it came.
const Said = struct { name: []const u8, payload: []const u8 };

fn saidOf(arena: std.mem.Allocator, ended: testing.Outcome) !Said {
    return foundation.json.decode(Said, arena, ended.said);
}

fn expectSaid(arena: std.mem.Allocator, ended: testing.Outcome, name: []const u8, payload: []const u8) !void {
    const said = try saidOf(arena, ended);
    try std.testing.expectEqualStrings(name, said.name);
    try std.testing.expectEqualStrings(payload, said.payload);
}

/// A fiber that asks the request `k1` and ends with its answer, counting the phases it ran.
const Counting = struct {
    runs: u32 = 0,

    fn phase(context: ?*anyopaque, run: *Phase) anyerror!void {
        const counting: *Counting = @ptrCast(@alignCast(context.?));
        counting.runs += 1;
        if (run.checkpoint.len == 0) {
            try run.request("held", "k1", "hello");
            return run.waitForMail("asked", "k1");
        }
        const answer = try run.mailOf("k1") orelse return run.waitForMail("asked", "k1");
        try run.take(answer.key);
        return run.done(answer.payload);
    }
};

/// Mail of `key` sent to the fiber at `path`, as a sender other than its request's handler sends it.
fn sendMail(siphon: *Siphon, arena: std.mem.Allocator, path: []const u8, key: []const u8, payload: []const u8) !void {
    const entry = (try siphon.runtime.volume.stat(&arena, path)).?;
    var changes: @import("runtime.zig").Changes = .{ .arena = arena };
    try changes.send(path, entry.directory.*.process.*.started, key, "note", payload);
    _ = try siphon.runtime.commit(&changes);
}

test "a fiber waiting for the mail of its request's key sleeps through mail of any other" {
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.open(&clock, .memory);
    defer siphon.close();
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var counting: Counting = .{};
    try siphon.runtime.register(.{ .kind = "test.counting", .context = &counting, .phase = Counting.phase });
    const fiber = try testing.startFiber(siphon, arena, "f1", "test.counting");
    for (0..3) |_| _ = try siphon.runtime.pump();
    try std.testing.expectEqual(@as(u32, 1), counting.runs);
    // Mail of keys before and after its own leaves it sleeping, as a receive of one type does.
    try sendMail(siphon, arena, fiber, "k0", "early");
    try sendMail(siphon, arena, fiber, "k2", "late");
    for (0..5) |_| _ = try siphon.runtime.pump();
    try std.testing.expectEqual(@as(u32, 1), counting.runs);
    try sendMail(siphon, arena, fiber, "k1", "its answer");
    const ended = try testing.pumpUntilEnded(siphon, &arena, fiber);
    // Ended with the mail's payload, written as JSON as everything a fiber writes is.
    try std.testing.expectEqualStrings("\"its answer\"", ended.said);
    try std.testing.expectEqual(@as(u32, 2), counting.runs);
}

/// Answers with the text asked in capitals.
fn shout(_: ?*anyopaque, request: *Request) anyerror!void {
    const asked = try foundation.json.decode([]const u8, request.arena(), request.payload);
    try request.answer(try std.ascii.allocUpperString(request.arena(), asked));
}

/// Fails, answering nothing.
fn breaks(_: ?*anyopaque, _: *Request) anyerror!void {
    return error.Broken;
}

/// Waits until a stop cancels it, then answers with what had come.
const Slow = struct {
    began: std.atomic.Value(bool) = .init(false),

    fn act(context: ?*anyopaque, request: *Request) anyerror!void {
        const slow: *Slow = @ptrCast(@alignCast(context.?));
        slow.began.store(true, .release);
        request.runtime.host.io.sleep(.fromSeconds(3600), .awake) catch |err| switch (err) {
            error.Canceled => return request.answer("partial"),
        };
        return request.answer("whole");
    }

    fn hasBegun(slow: *Slow) bool {
        return slow.began.load(.acquire);
    }
};

test "a fiber's request is acted on by its handler once made, and its answer comes back as mail of its key" {
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.open(&clock, .memory);
    defer siphon.close();
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const name: []const u8 = "shout";
    try siphon.runtime.register(Asker.program(&name));
    try siphon.runtime.handle("shout", .{ .act = shout });
    const fiber = try testing.startFiber(siphon, arena, "f1", "test.asker");
    const ended = try testing.pumpUntilEnded(siphon, &arena, fiber);
    try std.testing.expectEqual(.completed, ended.status);
    try expectSaid(arena, ended, "answered", "\"HELLO\"");
}

test "a handler that fails is answered for, as failed, with its error" {
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.open(&clock, .memory);
    defer siphon.close();
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const name: []const u8 = "break";
    try siphon.runtime.register(Asker.program(&name));
    try siphon.runtime.handle("break", .{ .act = breaks });
    const fiber = try testing.startFiber(siphon, arena, "f1", "test.asker");
    try expectSaid(arena, try testing.pumpUntilEnded(siphon, &arena, fiber), "failed", "Broken");
}

test "a stop cancels the task acting on a fiber's request, which answers at once with what had come" {
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.open(&clock, .memory);
    defer siphon.close();
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const name: []const u8 = "slow";
    var slow: Slow = .{};
    try siphon.runtime.register(Asker.program(&name));
    try siphon.runtime.handle("slow", .{ .context = &slow, .act = Slow.act });
    const fiber = try testing.startFiber(siphon, arena, "f1", "test.asker");
    try testing.pumpUntil(siphon, &slow, Slow.hasBegun);
    try testing.stopFiber(siphon, arena, fiber);
    const ended = try testing.pumpUntilEnded(siphon, &arena, fiber);
    try std.testing.expectEqual(.stopped, ended.status);
    try expectSaid(arena, ended, "answered", "\"partial\"");
}

/// Takes its time to wind down once cut off, as a handler that cleans up does: a second, then answers with what had come.
const Lingering = struct {
    began: std.atomic.Value(bool) = .init(false),

    fn act(context: ?*anyopaque, request: *Request) anyerror!void {
        const lingering: *Lingering = @ptrCast(@alignCast(context.?));
        lingering.began.store(true, .release);
        const io = request.runtime.host.io;
        io.sleep(.fromSeconds(3600), .awake) catch |err| switch (err) {
            // Cut off, its cleanup runs to its end: a cancellation is told once.
            error.Canceled => {
                try io.sleep(.fromSeconds(1), .awake);
                return request.answer("partial");
            },
        };
        return request.answer("whole");
    }

    fn hasBegun(lingering: *Lingering) bool {
        return lingering.began.load(.acquire);
    }
};

test "a request cut off is cut as a signal is sent: the loop goes on pumping while its handler winds down" {
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.open(&clock, .memory);
    defer siphon.close();
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const name: []const u8 = "linger";
    var lingering: Lingering = .{};
    try siphon.runtime.register(Asker.program(&name));
    try siphon.runtime.handle("linger", .{ .context = &lingering, .act = Lingering.act });
    const fiber = try testing.startFiber(siphon, arena, "f1", "test.asker");
    try testing.pumpUntil(siphon, &lingering, Lingering.hasBegun);
    try testing.stopFiber(siphon, arena, fiber);
    const io = std.testing.io;
    const began = std.Io.Clock.awake.now(io).toMilliseconds();
    var longest: i64 = 0;
    var ended: ?testing.Outcome = null;
    for (0..400) |_| {
        const before = std.Io.Clock.awake.now(io).toMilliseconds();
        const pumped = try siphon.runtime.pump();
        longest = @max(longest, std.Io.Clock.awake.now(io).toMilliseconds() - before);
        ended = try testing.outcomeOf(siphon, &arena, fiber);
        if (ended != null) break;
        if (!pumped.more) siphon.runtime.waitForNews(50);
    }
    try expectSaid(arena, ended.?, "answered", "\"partial\"");
    try std.testing.expect(std.Io.Clock.awake.now(io).toMilliseconds() - began >= 1_000);
    try std.testing.expect(longest < 250);
}

/// A handler that acts till it is cut off, as one the host's end cuts off does, counting the requests it began.
const Endless = struct {
    began: std.atomic.Value(u32) = .init(0),

    fn act(context: ?*anyopaque, request: *Request) anyerror!void {
        const endless: *Endless = @ptrCast(@alignCast(context.?));
        _ = endless.began.fetchAdd(1, .acq_rel);
        try request.runtime.host.io.sleep(.fromSeconds(3600), .awake);
        return request.answer("whole");
    }

    fn hasBegun(endless: *Endless) bool {
        return endless.began.load(.acquire) > 0;
    }
};

test "a request its handler acted on as the volume closed comes back to its fiber interrupted as it opens again, never acted on twice" {
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const place = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path, "volume" });
    const name: []const u8 = "endless";
    var fiber: []const u8 = undefined;
    {
        var endless: Endless = .{};
        const siphon = try testing.open(&clock, .{ .directory = place });
        defer siphon.close();
        try siphon.runtime.register(Asker.program(&name));
        try siphon.runtime.handle(name, .{ .context = &endless, .act = Endless.act });
        fiber = try testing.startFiber(siphon, arena, "f1", "test.asker");
        try testing.pumpUntil(siphon, &endless, Endless.hasBegun);
    }
    clock.now_ms += 1_000;
    var endless: Endless = .{};
    const siphon = try testing.open(&clock, .{ .directory = place });
    defer siphon.close();
    try siphon.runtime.register(Asker.program(&name));
    try siphon.runtime.handle(name, .{ .context = &endless, .act = Endless.act });
    try expectSaid(arena, try testing.pumpUntilEnded(siphon, &arena, fiber), Request.interrupted_name, "");
    try std.testing.expectEqual(@as(u32, 0), endless.began.load(.acquire));
}

test "a request no handler acts on, as a person's, waits on as the volume opens again, by its key, till it is answered" {
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const place = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path, "volume" });
    const name: []const u8 = "held";
    var fiber: []const u8 = undefined;
    {
        const siphon = try testing.open(&clock, .{ .directory = place });
        defer siphon.close();
        try siphon.runtime.register(Asker.program(&name));
        fiber = try testing.startFiber(siphon, arena, "f1", "test.asker");
        for (0..3) |_| _ = try siphon.runtime.pump();
        try std.testing.expect(try testing.outcomeOf(siphon, &arena, fiber) == null);
    }
    clock.now_ms += 1_000;
    const siphon = try testing.open(&clock, .{ .directory = place });
    defer siphon.close();
    try siphon.runtime.register(Asker.program(&name));
    for (0..3) |_| _ = try siphon.runtime.pump();
    try std.testing.expect(try testing.outcomeOf(siphon, &arena, fiber) == null);
    const entry = (try siphon.runtime.volume.stat(&arena, fiber)).?;
    var changes: @import("runtime.zig").Changes = .{ .arena = arena };
    try changes.answer(fiber, entry.directory.*.process.*.started, "k1", Request.answered_name, "\"later\"");
    _ = try siphon.runtime.commit(&changes);
    try expectSaid(arena, try testing.pumpUntilEnded(siphon, &arena, fiber), Request.answered_name, "\"later\"");
}

test "the loop runs in a task of its own, waking for commits and answers, until it is stopped" {
    const siphon = try Siphon.open(std.testing.allocator, .{ .io = std.testing.io }, .{});
    defer siphon.close();
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const name: []const u8 = "shout";
    try siphon.runtime.register(Asker.program(&name));
    try siphon.runtime.handle("shout", .{ .act = shout });
    try siphon.runtime.start();
    const fiber = try testing.startFiber(siphon, arena, "f1", "test.asker");
    var ended: ?testing.Outcome = null;
    for (0..400) |_| {
        ended = try testing.outcomeOf(siphon, &arena, fiber);
        if (ended != null) break;
        try std.testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    siphon.runtime.stop();
    try expectSaid(arena, ended.?, "answered", "\"HELLO\"");
}

/// Opens Siphon with `allocator`, makes a connection and a request with it, and lets them go.
fn openWhole(allocator: std.mem.Allocator) !void {
    const siphon = try Siphon.open(allocator, .{ .io = std.testing.io }, .{});
    defer siphon.close();
    // Neither the loop nor a host took the connection: both its holds are let go here.
    const protocol = @import("protocol.zig");
    const connection = try protocol.Connection.create(&siphon.clients, .{ .session = "s1", .scopes = protocol.Access.all_scopes });
    connection.release();
    connection.release();
    var made = std.mem.zeroes(h.beak_event);
    made.process = beak.bytes("system.process:f1");
    made.key = beak.bytes("k1");
    made.name = beak.bytes("shout");
    made.bytes = beak.bytes("hello");
    const request = try Request.init(siphon.runtime, &made, .{ .act = shout });
    request.deinit();
}

test "Siphon, a connection and a request each free what they took where an allocation fails on the way" {
    try @import("foundation").testing.checkAllAllocationFailures(openWhole, .{});
}

/// A job that waits, cancelled where its runtime closes first: whether it ran to its end, was finished on the loop, or
/// was dropped unfinished.
const Waiting = struct {
    io: std.Io,
    waits_ms: i64,
    ran: bool = false,
    finished: bool = false,
    dropped: bool = false,

    fn job(waiting: *Waiting) @import("runtime.zig").Runtime.Job {
        return .{ .context = waiting, .run = run, .finish = finish, .drop = drop };
    }

    fn run(context: *anyopaque, _: *@import("runtime.zig").Waits) void {
        const waiting: *Waiting = @ptrCast(@alignCast(context));
        waiting.io.sleep(.fromMilliseconds(waiting.waits_ms), .awake) catch return;
        waiting.ran = true;
    }

    fn finish(context: *anyopaque) void {
        const waiting: *Waiting = @ptrCast(@alignCast(context));
        waiting.finished = true;
    }

    fn drop(context: *anyopaque) void {
        const waiting: *Waiting = @ptrCast(@alignCast(context));
        waiting.dropped = true;
    }

    fn done(waiting: *const Waiting) bool {
        return waiting.finished;
    }
};

test "a job runs off the loop and is finished on it once its task ends; as the runtime closes, one still running is cancelled and dropped" {
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    var quick: Waiting = .{ .io = std.testing.io, .waits_ms = 1 };
    var slow: Waiting = .{ .io = std.testing.io, .waits_ms = 3_600_000 };
    {
        const siphon = try testing.open(&clock, .memory);
        defer siphon.close();
        try siphon.runtime.spawn(quick.job());
        try testing.pumpUntil(siphon, &quick, Waiting.done);
        try std.testing.expect(quick.ran and !quick.dropped);
        try siphon.runtime.spawn(slow.job());
    }
    // Closed, the runtime cancelled the job that waited and let go of it, never finishing it.
    try std.testing.expect(slow.dropped and !slow.finished and !slow.ran);
}

/// A fiber that waits for the mail `k1` or the time 5000, whichever comes first, and ends saying which came.
fn mailOrTime(_: ?*anyopaque, run: *Phase) anyerror!void {
    if (run.checkpoint.len == 0) return run.waitFor("waiting", .{ .mail = &.{"k1"}, .at = 5_000 });
    return run.done(if (try run.mailOf("k1") != null) "mail" else "time");
}

test "a fiber waiting for mail and a time at once wakes at whichever comes first" {
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.open(&clock, .memory);
    defer siphon.close();
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    try siphon.runtime.register(.{ .kind = "test.waking", .phase = mailOrTime });
    const by_mail = try testing.startFiber(siphon, arena, "f1", "test.waking");
    const by_time = try testing.startFiber(siphon, arena, "f2", "test.waking");
    for (0..3) |_| _ = try siphon.runtime.pump();
    try std.testing.expectEqual(null, try testing.outcomeOf(siphon, &arena, by_mail));
    try sendMail(siphon, arena, by_mail, "k1", "came");
    try std.testing.expectEqualStrings("\"mail\"", (try testing.pumpUntilEnded(siphon, &arena, by_mail)).said);
    try std.testing.expectEqual(null, try testing.outcomeOf(siphon, &arena, by_time));
    clock.now_ms = 5_000;
    try std.testing.expectEqualStrings("\"time\"", (try testing.pumpUntilEnded(siphon, &arena, by_time)).said);
}

/// A fiber that sleeps until a board of project a is there, then ends.
fn untilBoard(_: ?*anyopaque, run: *Phase) anyerror!void {
    if (run.checkpoint.len > 0) return run.done("woken");
    return run.waitFor("watching", .{ .until = .{ .kinds = &.{"test.board"}, .labels = &.{.{ .name = "test.project", .value = "a" }}, .scope = .{ .under = "" } } });
}

test "a fiber waiting on a selector sleeps through directories it does not pick, and wakes as one it picks is made" {
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.open(&clock, .memory);
    defer siphon.close();
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    try siphon.runtime.register(.{ .kind = "test.watching", .phase = untilBoard });
    const fiber = try testing.startFiber(siphon, arena, "f1", "test.watching");
    for (0..3) |_| _ = try siphon.runtime.pump();
    var other: @import("runtime.zig").Changes = .{ .arena = arena };
    try other.mkdir("test.board:1");
    try other.label("test.board:1", "test.project", "b");
    _ = try siphon.runtime.commit(&other);
    for (0..3) |_| _ = try siphon.runtime.pump();
    try std.testing.expectEqual(null, try testing.outcomeOf(siphon, &arena, fiber));
    var picked: @import("runtime.zig").Changes = .{ .arena = arena };
    try picked.mkdir("test.board:2");
    try picked.label("test.board:2", "test.project", "a");
    _ = try siphon.runtime.commit(&picked);
    try std.testing.expectEqualStrings("\"woken\"", (try testing.pumpUntilEnded(siphon, &arena, fiber)).said);
}
