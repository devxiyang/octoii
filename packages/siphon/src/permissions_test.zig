//! Permissions through a thread's turns, on the local machine: in default, an edit within the workspace goes ahead and
//! one beyond it waits on the person — answered once, always, which the project keeps, or not, with words its model
//! reads — a command runs within the sandbox, and one its model asks to run beyond it waits on the person, as a stop
//! ends a call that waits; in auto, what would ask is judged by a second model, the person asked where it blocks too
//! often or where no model is named to judge.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const ai = @import("ai");
const Siphon = @import("Siphon.zig");
const threads = @import("threads.zig");
const log = threads.log;
const settings = @import("settings.zig");
const tools = @import("tools.zig");
const permissions = tools.permissions;
const review = tools.review;
const testing = @import("testing.zig");
const beak = @import("beak.zig");
const h = beak.h;

/// A test's workspace on the local machine, and Siphon over the fake provider's model answering as `answers` say —
/// the model of each turn, and the one that judges calls in auto.
const Bench = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,
    workspace: []const u8,
    machine: h.beak_handle,
    fake: ai.testing.Fake,
    providers: [1]ai.driver.Provider,
    clock: testing.Clock = .{ .now_ms = 1_000 },
    siphon: *Siphon,

    /// Opens the bench, the machine sandboxing commands where `sandboxes` says.
    fn open(bench: *Bench, arena: Allocator, answers: []const ai.testing.fake.Answer, sandboxes: bool) !void {
        bench.tmp = std.testing.tmpDir(.{});
        errdefer bench.tmp.cleanup();
        try bench.tmp.dir.createDirPath(std.testing.io, "work");
        try bench.tmp.dir.createDirPath(std.testing.io, "outside");
        bench.root = try bench.tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
        bench.workspace = try std.fs.path.join(arena, &.{ bench.root, "work" });
        bench.machine = try testing.openLocalMachine();
        errdefer _ = h.beak_close(bench.machine);
        bench.fake = .init(arena, answers);
        bench.providers = .{.{ .id = "fake", .name = "Fake", .driver = bench.fake.bound(), .models = &.{ai.facts.asFacts(testing.model)} }};
        bench.clock = .{ .now_ms = 1_000 };
        bench.siphon = try Siphon.open(std.testing.allocator, .{ .io = std.testing.io, .clock = bench.clock.clock(), .machine = bench.machine, .sandboxes = sandboxes }, .{ .providers = &bench.providers });
    }

    fn close(bench: *Bench) void {
        bench.siphon.close();
        _ = h.beak_close(bench.machine);
        bench.tmp.cleanup();
    }

    /// A thread of `mode` working in the workspace, its project the workspace.
    fn thread(bench: *Bench, arena: Allocator, mode: threads.Mode) ![]const u8 {
        return threads.create(bench.siphon.runtime, arena, .{ .title = "Test", .model = "fake/m", .mode = mode, .workspace = bench.workspace, .project = bench.workspace }, "create");
    }

    /// Whether the file at `path`, in the test's folder, is there.
    fn has(bench: *Bench, path: []const u8) bool {
        bench.tmp.dir.access(std.testing.io, path, .{}) catch return false;
        return true;
    }
};

/// What a permission request asks of the person, as its payload has it.
fn askedOf(arena: Allocator, request: threads.Open) !permissions.Asked {
    return foundation.json.decode(permissions.Asked, arena, request.payload.?.text);
}

/// Answers the person's way the request `key` of the thread `tid`, which must fit.
fn answer(siphon: *Siphon, arena: Allocator, tid: []const u8, key: []const u8, given: []const u8) !void {
    try std.testing.expect((try threads.answer(siphon.runtime, arena, tid, key, .{ .text = given })) == .given);
}

/// Delivers `text` to the thread `tid` and pumps until it settles replied.
fn turn(siphon: *Siphon, arena: Allocator, tid: []const u8, text: []const u8, operation: []const u8) !void {
    _ = try threads.deliver(siphon.runtime, arena, tid, testing.said(text), operation);
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
}

test "in default, an edit within the workspace goes ahead; one beyond it waits: once lets it alone, always grants the project every edit, a rejection is told" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var bench: Bench = undefined;
    try bench.open(arena, &.{
        try testing.streamed(arena, &.{testing.call("c1", "write", "{\"path\":\"a.txt\",\"content\":\"a\\n\"}")}),            try testing.message(arena, "a"),
        try testing.streamed(arena, &.{testing.call("c2", "write", "{\"path\":\"../outside/b.txt\",\"content\":\"b\\n\"}")}), try testing.message(arena, "b"),
        try testing.streamed(arena, &.{testing.call("c3", "write", "{\"path\":\"../outside/c.txt\",\"content\":\"c\\n\"}")}), try testing.message(arena, "c"),
        try testing.streamed(arena, &.{testing.call("c4", "write", "{\"path\":\"../outside/d.txt\",\"content\":\"d\\n\"}")}), try testing.message(arena, "d"),
        try testing.streamed(arena, &.{testing.call("c5", "shell", "{\"command\":\"rm -rf build\"}")}),                       try testing.message(arena, "not removed"),
        try testing.streamed(arena, &.{testing.call("c6", "shell", "{\"command\":\"touch e.txt\"}")}),
    }, false);
    defer bench.close();
    const siphon = bench.siphon;
    const tid = try bench.thread(arena, .default);

    // Within the workspace, the edit goes ahead with no one asked.
    try turn(siphon, arena, tid, "write a", "op-1");
    try std.testing.expect(bench.has("work/a.txt"));

    // Beyond it, the edit waits on the person, its request saying what it edits and what an always grants.
    _ = try threads.deliver(siphon.runtime, arena, tid, testing.said("write b"), "op-2");
    const first = try testing.pumpUntilAsked(siphon, arena, tid, permissions.request_name);
    const asked = try askedOf(arena, first);
    try std.testing.expectEqualStrings("write", asked.tool);
    try std.testing.expectEqual(.edit, asked.access.action);
    try std.testing.expectEqualStrings(try std.fs.path.join(arena, &.{ bench.root, "outside", "b.txt" }), asked.access.resources[0]);
    try std.testing.expectEqualStrings("*", asked.access.save[0]);
    try std.testing.expect(!bench.has("outside/b.txt"));
    try std.testing.expect((try threads.answer(siphon.runtime, arena, tid, first.key, .{ .text = "{\"reply\":\"maybe\"}" })) == .unfit);
    try answer(siphon, arena, tid, first.key, "{\"reply\":\"once\"}");
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try std.testing.expect(bench.has("outside/b.txt"));

    // Once lets that edit alone: the next asks again; always grants the project every edit from then on.
    _ = try threads.deliver(siphon.runtime, arena, tid, testing.said("write c"), "op-3");
    try answer(siphon, arena, tid, (try testing.pumpUntilAsked(siphon, arena, tid, permissions.request_name)).key, "{\"reply\":\"always\"}");
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    const granted = try permissions.grantsOf(siphon.runtime, arena, bench.workspace);
    try std.testing.expectEqualStrings(bench.workspace, granted.folder);
    try std.testing.expectEqual(.edit, granted.allow[0].action);
    try std.testing.expectEqualStrings("*", granted.allow[0].pattern);
    try turn(siphon, arena, tid, "write d", "op-4");
    try std.testing.expect(bench.has("outside/d.txt"));

    // On a machine that sandboxes no command, each command asks; rejected, it never runs, and the model reads the
    // person's words.
    _ = try threads.deliver(siphon.runtime, arena, tid, testing.said("remove the build"), "op-5");
    const removing = try testing.pumpUntilAsked(siphon, arena, tid, permissions.request_name);
    const command = try askedOf(arena, removing);
    try std.testing.expectEqual(.command, command.access.action);
    try std.testing.expectEqualStrings("rm -rf build", command.access.resources[0]);
    try std.testing.expectEqualStrings("rm *", command.access.save[0]);
    try answer(siphon, arena, tid, removing.key, "{\"reply\":\"reject\",\"message\":\"keep it for now\"}");
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    const told = try testing.toldOutputs(&bench.fake, arena, 9);
    try std.testing.expectEqualStrings("[the person rejected this call: keep it for now]", told[told.len - 1]);

    // A stop ends a call that waits on the person, its request gone with it.
    _ = try threads.deliver(siphon.runtime, arena, tid, testing.said("touch e"), "op-6");
    _ = try testing.pumpUntilAsked(siphon, arena, tid, permissions.request_name);
    try threads.stop(siphon.runtime, arena, tid, "person");
    try std.testing.expectEqual(threads.Status.stopped, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try std.testing.expect(!bench.has("work/e.txt"));
    const lines = try log.lines(siphon.runtime.volume, &arena, try threads.pathOf(arena, tid));
    try std.testing.expectEqual(log.CallStatus.rejected, (try statusOf(arena, lines, "c5")).?);
    try std.testing.expectEqual(log.CallStatus.stopped, (try statusOf(arena, lines, "c6")).?);
}

/// The status the result of the call `call_id` ended with, in the log's `lines`; none where it has none.
fn statusOf(arena: Allocator, lines: []const []const u8, call_id: []const u8) !?log.CallStatus {
    for (lines) |line| {
        if (!std.mem.eql(u8, (try log.headOf(arena, line)).type, "result")) continue;
        const result = try foundation.json.decode(log.Result, arena, line);
        if (std.mem.eql(u8, result.call_output.call_id, call_id)) return result.status;
    }
    return null;
}

test "in default, a command runs within the sandbox, and one its model asks to run beyond it waits on the person" {
    if (builtin.target.os.tag != .macos) return error.SkipZigTest;
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var bench: Bench = undefined;
    // Within the workspace a command writes as ever; beyond it the sandbox refuses the write, till the person lets it
    // run beyond.
    try bench.open(arena, &.{
        try testing.streamed(arena, &.{testing.call("c1", "shell", "{\"command\":\"echo in > in.txt && echo out > ../outside/out.txt\"}")}),
        try testing.streamed(arena, &.{testing.call("c2", "shell", "{\"command\":\"echo out > ../outside/out.txt\",\"escalate\":true,\"justification\":\"the notes live beside the workspace\"}")}),
        try testing.message(arena, "written"),
    }, true);
    defer bench.close();
    const siphon = bench.siphon;
    const tid = try bench.thread(arena, .default);
    _ = try threads.deliver(siphon.runtime, arena, tid, testing.said("write both"), "op-1");
    const beyond = try testing.pumpUntilAsked(siphon, arena, tid, permissions.request_name);
    try std.testing.expect(bench.has("work/in.txt"));
    try std.testing.expect(!bench.has("outside/out.txt"));
    const sandboxed = (try testing.toldOutputs(&bench.fake, arena, 1))[0];
    try std.testing.expect(std.mem.endsWith(u8, sandboxed, "[exit 1]"));
    const asked = try askedOf(arena, beyond);
    try std.testing.expect(asked.access.escalate);
    try std.testing.expectEqualStrings("the notes live beside the workspace", asked.access.justification.?);
    // A line that writes a file by a redirection offers nothing an always could grant.
    try std.testing.expectEqual(@as(usize, 0), asked.access.save.len);
    try answer(siphon, arena, tid, beyond.key, "{\"reply\":\"once\"}");
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try std.testing.expect(bench.has("outside/out.txt"));
}

test "in auto, what would ask is judged by a second model: let go ahead it runs, blocked the model reads why, and blocked three times in a row the person decides" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var bench: Bench = undefined;
    try bench.open(arena, &.{
        // A command that may write, judged and let go ahead.
        try testing.streamed(arena, &.{testing.call("c1", "shell", "{\"command\":\"touch made.txt\"}")}), try testing.message(arena, "{\"allow\":true,\"reason\":\"\"}"),                                     try testing.message(arena, "made"),
        // One that removes it, blocked: the model reads why.
        try testing.streamed(arena, &.{testing.call("c2", "shell", "{\"command\":\"rm made.txt\"}")}),    try testing.message(arena, "{\"allow\":false,\"reason\":\"the person did not ask to delete it\"}"), try testing.message(arena, "kept"),
        // Blocked twice more in a row, the third asks the person, who lets it.
        try testing.streamed(arena, &.{testing.call("c3", "shell", "{\"command\":\"rm made.txt\"}")}),    try testing.message(arena, "{\"allow\":false,\"reason\":\"still not asked\"}"),                     try testing.message(arena, "kept"),
        try testing.streamed(arena, &.{testing.call("c4", "shell", "{\"command\":\"rm made.txt\"}")}),    try testing.message(arena, "{\"allow\":false,\"reason\":\"still not asked\"}"),                     try testing.message(arena, "removed"),
    }, false);
    defer bench.close();
    const siphon = bench.siphon;
    try settings.set(siphon.runtime, arena, "test", .{ .environment = .{ .review_model = "fake/m" } });
    const tid = try bench.thread(arena, .auto);

    try turn(siphon, arena, tid, "make it", "op-1");
    try std.testing.expect(bench.has("work/made.txt"));
    // The judge was asked with the person's words and the call, none of the model's.
    const judged = bench.fake.requests.items[1].input.?.parts;
    try std.testing.expectEqualStrings(@import("agent.zig").review.policy, judged[0].input_message.content.text);
    try std.testing.expect(std.mem.indexOf(u8, judged[1].input_message.content.text, "person: make it\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, judged[1].input_message.content.text, "<call>\nshell {\"command\":\"touch made.txt\"}\n</call>"));
    // It answers in JSON of the verdict's schema.
    try std.testing.expectEqualStrings("verdict", bench.fake.requests.items[1].text.?.format.?.json_schema.name);

    try turn(siphon, arena, tid, "remove it", "op-2");
    try std.testing.expect(bench.has("work/made.txt"));
    const blocked = (try testing.toldOutputs(&bench.fake, arena, 5));
    try std.testing.expect(std.mem.startsWith(u8, blocked[blocked.len - 1], "[a second model judged this call and blocked it: the person did not ask to delete it"));
    try turn(siphon, arena, tid, "remove it", "op-3");

    _ = try threads.deliver(siphon.runtime, arena, tid, testing.said("remove it now"), "op-4");
    const asked = try testing.pumpUntilAsked(siphon, arena, tid, permissions.request_name);
    try std.testing.expectEqualStrings("still not asked", (try askedOf(arena, asked)).doubt.?);
    try answer(siphon, arena, tid, asked.key, "{\"reply\":\"once\"}");
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try std.testing.expect(!bench.has("work/made.txt"));
    // The person letting it begins the count again.
    const entry = (try siphon.runtime.volume.stat(&arena, try threads.pathOf(arena, tid))).?;
    try std.testing.expectEqualStrings("0", beak.annotationOf(entry, review.blocked_in_a_row).?);
    try std.testing.expectEqualStrings("3", beak.annotationOf(entry, review.blocked_in_all).?);
}

test "in auto, with no model named to judge, what would ask asks the person, saying why" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var bench: Bench = undefined;
    try bench.open(arena, &.{
        try testing.streamed(arena, &.{testing.call("c1", "shell", "{\"command\":\"touch made.txt\"}")}),
        try testing.message(arena, "made"),
    }, false);
    defer bench.close();
    const siphon = bench.siphon;
    const tid = try bench.thread(arena, .auto);
    _ = try threads.deliver(siphon.runtime, arena, tid, testing.said("make it"), "op-1");
    const asked = try testing.pumpUntilAsked(siphon, arena, tid, permissions.request_name);
    try std.testing.expectEqualStrings("no model is named to judge calls in auto", (try askedOf(arena, asked)).doubt.?);
    try answer(siphon, arena, tid, asked.key, "{\"reply\":\"once\"}");
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try std.testing.expect(bench.has("work/made.txt"));
}
