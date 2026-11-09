//! A thread's model asked through `ai`, over a fake provider that answers from a script: the request rendered from the
//! log, the reply kept as it came, a failure that may pass asked again after its wait, one that cannot failing the turn;
//! a window too full for its model, or refused as too long, recapped and asked again in a window of its own.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const ai = @import("ai");
const Siphon = @import("Siphon.zig");
const threads = @import("threads.zig");
const log = @import("threads.zig").log;
const testing = @import("testing.zig");
const compaction = @import("agent.zig").compaction;
const models = @import("agent.zig").models;
const compacting = @import("agent.zig").compacting;
const context = @import("agent.zig").context;
const Changes = @import("runtime.zig").Changes;

const model = testing.model;

/// A reply of the message `text`, streamed whole.
fn reply(arena: Allocator, text: []const u8) !ai.testing.fake.Answer {
    return replyTaking(arena, text, null);
}

/// A reply of the message `text`, streamed whole, whose request took `context_tokens` as its provider says.
fn replyTaking(arena: Allocator, text: []const u8, context_tokens: ?u64) !ai.testing.fake.Answer {
    const message: vocabulary.OutputItem = .{ .output_message = .{ .id = "m1", .content = .{ .parts = try arena.dupe(vocabulary.OutputContent, &.{.{ .output_text = .{ .text = text } }}) } } };
    const output = try arena.dupe(vocabulary.OutputItem, &.{message});
    const extension: ?vocabulary.extensions.ResponseExtension = if (context_tokens) |taken| .{ .context_tokens = taken } else null;
    return .{ .events = try arena.dupe(vocabulary.ResponseStreamEvent, &.{
        .{ .created = .{ .response = .{ .id = "r", .status = .in_progress, .output = &.{} }, .sequence_number = 0 } },
        .{ .output_item_added = .{ .item = message, .output_index = 0, .sequence_number = 1 } },
        .{ .output_item_done = .{ .item = message, .output_index = 0, .sequence_number = 2 } },
        .{ .completed = .{ .response = .{ .id = "r", .status = .completed, .output = output, .octoii = extension }, .sequence_number = 3 } },
    }) };
}

/// A failure of `kind`, after nothing streamed.
fn failure(kind: ai.failure.Kind) ai.testing.fake.Answer {
    return .{ .events = &.{}, .failure = .init(kind, "the provider failed") };
}

const said = testing.said;

fn openOver(clock: *testing.Clock, providers: []const ai.driver.Provider) !*Siphon {
    return Siphon.open(std.testing.allocator, .{ .io = std.testing.io, .clock = clock.clock() }, .{ .providers = providers });
}

test "a turn asks its model through ai, the request rendered from the log, and keeps the reply as it came" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var fake: ai.testing.Fake = .init(arena, &.{ try reply(arena, "Hi"), try reply(arena, "Again") });
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try openOver(&clock, &providers);
    defer siphon.close();
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m" }, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, said("hello"), "op-1");
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    _ = try threads.deliver(siphon.runtime, arena, tid, said("again"), "op-2");
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);

    // The second request is the log so far: what the model was told before the first turn, a developer message ahead
    // of every input; the first input, the reply's message, the second input — the second turn told nothing new.
    try std.testing.expectEqual(@as(usize, 2), fake.requests.items.len);
    const sent = fake.requests.items[1].input.?.parts;
    try std.testing.expectEqual(@as(usize, 4), sent.len);
    const told = sent[0].input_message;
    try std.testing.expectEqual(.developer, told.role);
    try std.testing.expect(std.mem.startsWith(u8, told.content.parts[0].input_text.text, "You are a coding agent in Octoii"));
    try std.testing.expect(std.mem.startsWith(u8, told.content.parts[1].input_text.text, "<environment>"));
    try std.testing.expectEqualStrings("hello", sent[1].input_message.content.text);
    try std.testing.expectEqualStrings("Hi", sent[2].output_message.content.parts[0].output_text.text);
    try std.testing.expectEqualStrings("again", sent[3].input_message.content.text);
    try std.testing.expect(fake.requests.items[1].instructions == null);
    const lines = try log.lines(siphon.runtime.volume, &arena, try threads.pathOf(arena, tid));
    const kept = try foundation.json.decode(log.Reply, arena, lines[5]);
    try std.testing.expect(std.mem.indexOf(u8, kept.response.text, "\"Again\"") != null);
}

test "a turn the person stopped is told to its model where it ended: its reply as cut, then a note that they stopped it" {
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.open(&clock, .memory);
    defer siphon.close();
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m" }, "create");
    try @import("log_test.zig").writeSegments(siphon, arena, try threads.pathOf(arena, tid), &.{
        \\{"id":"1","type":"input","delivery_id":"d1","actor":"person","message":{"role":"user","content":"write a story"}}
        \\{"id":"2","type":"reply","request":"q2","response":{"id":"r","status":"incomplete","incomplete_details":{"reason":"cancelled"},"output":[{"type":"message","id":"m1","role":"assistant","status":"incomplete","content":[{"type":"output_text","text":"Once upon","annotations":[]}]}]},"cancelled":true}
        \\{"id":"3","type":"turn-end","turn":"t1","outcome":"stopped","reason":"stopped"}
        \\{"id":"4","type":"input","delivery_id":"d4","actor":"person","message":{"role":"user","content":"what is a log?"}}
        \\
    });
    const rendered = try models.render(siphon.runtime, &arena, .{ .thread = tid, .until = "4", .model = "fake/m" }, null);
    const items = rendered.input.?.parts;
    try std.testing.expectEqual(@as(usize, 4), items.len);
    try std.testing.expect(items[1] == .output_message);
    try std.testing.expectEqual(.developer, items[2].input_message.role);
    try std.testing.expectEqualStrings(models.stopped_note, items[2].input_message.content.text);
    try std.testing.expectEqualStrings("what is a log?", items[3].input_message.content.text);
}

test "a failure that may pass is asked again once its wait passes; one that cannot fails the turn" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var fake: ai.testing.Fake = .init(arena, &.{ failure(.rate_limit), try reply(arena, "Hi"), failure(.invalid_request) });
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try openOver(&clock, &providers);
    defer siphon.close();
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m" }, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, said("hello"), "op-1");
    // Rate limited: the turn sleeps till its wait passes, then asks again.
    const Retrying = struct {
        siphon: *Siphon,
        tid: []const u8,
        arena: Allocator,
        /// Whether the turn sleeps till a time, as the thread's state shows: the wait before it asks again.
        fn waits(retrying: *const @This()) bool {
            const now = threads.state(retrying.siphon.runtime, retrying.arena, retrying.tid) catch return false;
            for (now.processes) |process| if (std.mem.eql(u8, process.program, threads.turn_program)) return process.until != null;
            return false;
        }
    };
    const retrying: Retrying = .{ .siphon = siphon, .tid = tid, .arena = arena };
    try testing.pumpUntil(siphon, &retrying, Retrying.waits);
    try std.testing.expectEqual(@as(usize, 1), fake.requests.items.len);
    clock.now_ms += 2_000;
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try std.testing.expectEqual(@as(usize, 2), fake.requests.items.len);

    // A request the provider refuses is not asked again: the turn fails. Each failure is kept for the record.
    _ = try threads.deliver(siphon.runtime, arena, tid, said("again"), "op-2");
    try std.testing.expectEqual(threads.Status.failed, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try std.testing.expectEqual(@as(usize, 3), fake.requests.items.len);
    const lines = try expectKinds(siphon, arena, tid, &.{ "system", "input", "failure", "reply", "turn-end", "input", "failure", "turn-end" });
    const limited = try foundation.json.decode(log.Failure, arena, lines[2]);
    try std.testing.expect(std.mem.indexOf(u8, limited.response.text, "rate_limit") != null);
    // The failed attempt and the reply that came after are answers of two requests.
    try std.testing.expect(!std.mem.eql(u8, limited.request, (try foundation.json.decode(log.Reply, arena, lines[3])).request));
}

/// The types of the entries the log of the thread `tid` holds, in order, as `expected` names them.
fn expectKinds(siphon: *Siphon, arena: Allocator, tid: []const u8, expected: []const []const u8) ![]const []const u8 {
    const lines = try log.lines(siphon.runtime.volume, &arena, try threads.pathOf(arena, tid));
    try std.testing.expectEqual(expected.len, lines.len);
    for (expected, lines) |kind, line| try std.testing.expectEqualStrings(kind, (try log.headOf(arena, line)).type);
    return lines;
}

test "a window too full for its model is recapped before its model is asked, and a new window begins with the recap" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    // A model that takes little past what a window keeps free; the first reply says its request took more.
    var small = model;
    small.context_length = compaction.reserve_tokens + 2_000;
    var fake: ai.testing.Fake = .init(arena, &.{ try replyTaking(arena, "Hi", 3_000), try reply(arena, "They said hello."), try reply(arena, "Done") });
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(small)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try openOver(&clock, &providers);
    defer siphon.close();
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m" }, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, said("hello"), "op-1");
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    _ = try threads.deliver(siphon.runtime, arena, tid, said("again"), "op-2");
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);

    // The recap is asked of the window up to its cut, the latest input kept out of it, the recap asked for after.
    try std.testing.expectEqual(@as(usize, 3), fake.requests.items.len);
    const recapping = fake.requests.items[1].input.?.parts;
    try std.testing.expectEqual(@as(usize, 4), recapping.len);
    try std.testing.expectEqualStrings("hello", recapping[1].input_message.content.text);
    try std.testing.expectEqualStrings("Hi", recapping[2].output_message.content.parts[0].output_text.text);
    try std.testing.expectEqualStrings(compaction.instruction, recapping[3].input_message.content.text);
    // The window after: what the model is told, gathered anew, the recap, then the input kept as it was given.
    const sent = fake.requests.items[2].input.?.parts;
    try std.testing.expectEqual(@as(usize, 3), sent.len);
    try std.testing.expect(std.mem.startsWith(u8, sent[0].input_message.content.parts[0].input_text.text, "You are a coding agent in Octoii"));
    try std.testing.expectEqualStrings("<recap>\nThey said hello.\n</recap>", sent[1].input_message.content.text);
    try std.testing.expectEqualStrings("again", sent[2].input_message.content.text);
    // Every entry once in the log: the compaction where the window was cut, then all the new window is told.
    const lines = try expectKinds(siphon, arena, tid, &.{ "system", "input", "reply", "turn-end", "input", "compaction", "system", "reply", "turn-end" });
    const made = try foundation.json.decode(log.Compaction, arena, lines[5]);
    try std.testing.expectEqualStrings("They said hello.", try compaction.recapIn(arena, made));
    try std.testing.expectEqualStrings((try log.headOf(arena, lines[4])).id, made.kept);
    try std.testing.expectEqualStrings(made.kept, made.from);
}

test "a request its provider refuses as too long is asked again in a recapped window, once for one request" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var fake: ai.testing.Fake = .init(arena, &.{ try reply(arena, "Hi"), failure(.context_overflow), try reply(arena, "They said hello."), failure(.context_overflow) });
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try openOver(&clock, &providers);
    defer siphon.close();
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m" }, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, said("hello"), "op-1");
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    _ = try threads.deliver(siphon.runtime, arena, tid, said("again"), "op-2");
    // Refused, recapped, asked again in the new window — and refused again, the turn fails: a window is compacted once
    // for one request.
    try std.testing.expectEqual(threads.Status.failed, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try std.testing.expectEqual(@as(usize, 4), fake.requests.items.len);
    const sent = fake.requests.items[3].input.?.parts;
    try std.testing.expectEqual(@as(usize, 3), sent.len);
    try std.testing.expectEqualStrings("<recap>\nThey said hello.\n</recap>", sent[1].input_message.content.text);
    try std.testing.expectEqualStrings("again", sent[2].input_message.content.text);
    // Each refusal kept for the record, by the request it answered, before what came of it.
    const lines = try expectKinds(siphon, arena, tid, &.{ "system", "input", "reply", "turn-end", "input", "failure", "compaction", "system", "failure", "turn-end" });
    const refused = try foundation.json.decode(log.Failure, arena, lines[5]);
    try std.testing.expect(std.mem.indexOf(u8, refused.response.text, "context_overflow") != null);
    try std.testing.expect(!std.mem.eql(u8, refused.request, (try foundation.json.decode(log.Failure, arena, lines[8])).request));
}

test "the person compacts a thread's window in the background, once at a time, and is shown what fills it" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var fake: ai.testing.Fake = .init(arena, &.{ try reply(arena, "Hi"), try reply(arena, "Fine."), try reply(arena, "They said hello.") });
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try openOver(&clock, &providers);
    defer siphon.close();
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m" }, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, said("hello"), "op-1");
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    _ = try threads.deliver(siphon.runtime, arena, tid, said("how did it go?"), "op-2");
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    const thread = try threads.pathOf(arena, tid);

    // What fills the window: what Octoii tells the model, its tools, the person's messages and the replies, each a
    // share of the window's tokens; nothing recapped yet.
    const before = try context.of(siphon.runtime, &arena, thread);
    try std.testing.expect(before.tokens > 0);
    try std.testing.expect(shareOf(before, .system) > 0 and shareOf(before, .messages) > 0 and shareOf(before, .replies) > 0);
    try std.testing.expectEqual(@as(u64, 0), shareOf(before, .recap));
    var whole: u64 = 0;
    for (before.parts) |share| whole += share.tokens;
    try std.testing.expect(whole <= before.tokens);

    // Asked, the thread compacts; asked again while it does, nothing more is started.
    try std.testing.expect(try asked(siphon, arena, thread));
    try std.testing.expect(!try asked(siphon, arena, thread));
    try std.testing.expectEqual(.completed, (try testing.pumpUntilEnded(siphon, &arena, try compacting.pathOf(arena, thread))).status);
    _ = try expectKinds(siphon, arena, tid, &.{ "system", "input", "reply", "turn-end", "input", "reply", "turn-end", "compaction", "system" });
    try std.testing.expect(shareOf(try context.of(siphon.runtime, &arena, thread), .recap) > 0);

    // Ended, it starts anew as it is asked again: with nothing more to recap, it ends having written nothing.
    try std.testing.expect(try asked(siphon, arena, thread));
    try std.testing.expectEqual(.completed, (try testing.pumpUntilEnded(siphon, &arena, try compacting.pathOf(arena, thread))).status);
    try std.testing.expectEqual(@as(usize, 3), fake.requests.items.len);
}

/// Has the thread at `thread` compacted as the person asks: whether its compaction was started.
fn asked(siphon: *Siphon, arena: Allocator, thread: []const u8) !bool {
    var changes: Changes = .{ .arena = arena };
    const started = try compacting.start(&changes, siphon.runtime, &arena, thread);
    if (started) _ = try siphon.runtime.commit(&changes);
    return started;
}

/// The tokens `composition` gives `part`; none where it gives it none.
fn shareOf(composition: context.Composition, part: context.Part) u64 {
    for (composition.parts) |share| if (share.part == part) return share.tokens;
    return 0;
}
