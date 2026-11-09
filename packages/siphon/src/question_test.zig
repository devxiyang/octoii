//! `question` through a thread's turns: its request waits on the person with the schema its answer fits, made from its
//! questions; an answer that does not fit is refused, one that fits comes back to the model as each question and what
//! was chosen or written; dismissed, the questions come back as a call the person declined, and the turn goes on; and a
//! stop reaches a question that waits, as it reaches every call.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const ai = @import("ai");
const threads = @import("threads.zig");
const log = threads.log;
const question = @import("tools.zig").question;
const testing = @import("testing.zig");

const asked =
    \\{"questions":[{"question":"Which stack?","header":"Stack","options":[{"label":"Bun"},{"label":"Node"}]},
    \\{"question":"Which checks?","header":"Checks","options":[{"label":"lint"},{"label":"test"}],"multiple":true},
    \\{"question":"Anything else?","header":"Notes"}]}
;

test "a question waits on the person, refuses an answer that does not fit, and tells the model what they chose and wrote" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var fake: ai.testing.Fake = .init(arena, &.{
        try testing.streamed(arena, &.{testing.call("c1", "question", asked)}), try testing.message(arena, "Bun it is."),
        try testing.streamed(arena, &.{testing.call("c2", "question", asked)}), try testing.message(arena, "I will pick for you."),
        try testing.streamed(arena, &.{testing.call("c3", "question", asked)}),
    });
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(testing.model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.openOver(&clock, .memory, &providers);
    defer siphon.close();
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m" }, "create");

    // The person is asked, the form of their answer shown with the questions.
    _ = try threads.deliver(siphon.runtime, arena, tid, testing.said("set it up"), "op-1");
    const first = try testing.pumpUntilAsked(siphon, arena, tid, question.request_name);
    try std.testing.expect(std.mem.indexOf(u8, first.payload.?.text, "Which checks?") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.answer.?.text, "\"prefixItems\"") != null);
    // Two choices for a question of one, or too few answers, do not fit.
    for ([_][]const u8{ "{\"answers\":[[\"Bun\",\"Node\"],[],[]]}", "{\"answers\":[[\"Bun\"]]}", "{\"dismissed\":false}" }) |unfit| {
        try std.testing.expect((try threads.answer(siphon.runtime, arena, tid, first.key, .{ .text = unfit })) == .unfit);
    }
    const fit = "{\"answers\":[[\"Bun\"],[\"lint\",\"also e2e\"],[]]}";
    try std.testing.expect((try threads.answer(siphon.runtime, arena, tid, first.key, .{ .text = fit })) == .given);
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try std.testing.expectEqualStrings(
        \\The person answered:
        \\"Which stack?"="Bun"
        \\"Which checks?"="lint, also e2e"
        \\"Anything else?"="Unanswered"
    , (try testing.toldOutputs(&fake, arena, 1))[0]);

    // Dismissed, the questions come back as a call the person declined, and the turn goes on.
    _ = try threads.deliver(siphon.runtime, arena, tid, testing.said("ask me again"), "op-2");
    const second = try testing.pumpUntilAsked(siphon, arena, tid, question.request_name);
    try std.testing.expect((try threads.answer(siphon.runtime, arena, tid, second.key, .{ .text = "{\"dismissed\":true}" })) == .given);
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    const declined = try lastResult(arena, try log.lines(siphon.runtime.volume, &arena, try threads.pathOf(arena, tid)));
    try std.testing.expectEqual(log.CallStatus.rejected, declined.status);
    const told = try testing.toldOutputs(&fake, arena, 3);
    try std.testing.expectEqualStrings("[the person dismissed the questions, answering none]", told[told.len - 1]);

    // Stopped while it waits, the question ends stopped, as every call a stop reaches.
    _ = try threads.deliver(siphon.runtime, arena, tid, testing.said("and again"), "op-3");
    _ = try testing.pumpUntilAsked(siphon, arena, tid, question.request_name);
    try threads.stop(siphon.runtime, arena, tid, "person");
    try std.testing.expectEqual(threads.Status.stopped, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    const lines = try log.lines(siphon.runtime.volume, &arena, try threads.pathOf(arena, tid));
    const last = try lastResult(arena, lines);
    try std.testing.expectEqual(log.CallStatus.stopped, last.status);
    try std.testing.expectEqualStrings("[stopped before the person answered]", last.call_output.output.text);
}

/// The last result in the log's `lines`.
fn lastResult(arena: Allocator, lines: []const []const u8) !log.Result {
    var at = lines.len;
    while (at > 0) {
        at -= 1;
        if (std.mem.eql(u8, (try log.headOf(arena, lines[at])).type, "result")) return foundation.json.decode(log.Result, arena, lines[at]);
    }
    return error.NoResult;
}
