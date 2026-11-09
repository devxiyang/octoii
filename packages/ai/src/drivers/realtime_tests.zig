//! Realtime transcription against its recorded sessions — OpenAI's, Deepgram's and xAI's — played through the real
//! `Models`, and against sockets whose provider a test plays by hand.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const SocketReplay = foundation.socket_replay.SocketReplay;
const vocabulary = @import("vocabulary");
const realtime = vocabulary.realtime;
const ServerEvent = realtime.ServerEvent;
const seam = @import("../driver.zig");
const Failure = @import("../failure.zig").Failure;
const Models = @import("../Models.zig");
const RealtimeSession = Models.RealtimeSession;
const fixtures = @import("../testing/fixtures.zig");
const host_models = @import("../testing/host_models.zig");
const Scripted = @import("../testing/scripted_socket.zig").Scripted;
const session_ = @import("../wire/realtime/session.zig");

/// A provider that serves realtime transcription: its driver, the models and key its tests use, and how it sends the
/// key.
const Setup = struct {
    driver: *const seam.Driver,
    models: ?*const fn (Allocator) anyerror![]const @import("../catalogue/facts.zig").ModelFacts,
    key: []const u8,
    authorization: []const u8,

    fn options(setup: Setup, arena: Allocator, connector: foundation.websocket.Connector) !fixtures.Options {
        return .{ .driver = setup.driver, .key = setup.key, .models = if (setup.models) |models| try models(arena) else &.{}, .connector = connector };
    }
};

const openai: Setup = .{ .driver = &@import("openai.zig").driver, .models = host_models.openai, .key = "sk-test", .authorization = "Bearer sk-test" };
const deepgram: Setup = .{ .driver = &@import("deepgram.zig").driver, .models = host_models.deepgram, .key = "dg-test", .authorization = "Token dg-test" };
const xai: Setup = .{ .driver = &@import("xai.zig").driver, .models = null, .key = "xai-test", .authorization = "Bearer xai-test" };

/// A recorded realtime session: its request, the client's events, and its sockets; or a WebRTC call's exchanges.
const Fixture = struct {
    source: []const u8,
    kind: []const u8,
    request: std.json.Value,
    events: []const realtime.ClientEvent = &.{},
    sockets: []const foundation.socket_replay.RecordedSocket = &.{},
    exchanges: []const foundation.replay.Exchange = &.{},
};

fn fixtureOf(arena: Allocator, provider: []const u8, name: []const u8) !Fixture {
    const path = try arena.print("test/fixtures/{s}/{s}.json", .{ provider, name });
    return foundation.json.decode(Fixture, arena, try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, .limited(16 << 20)));
}

/// `Models` whose sockets replay the fixture `name` of `setup`'s provider, and the replay.
const Replayed = struct { fixture: Fixture, models: *Models, replay: *SocketReplay };

fn replayed(arena: Allocator, setup: Setup, name: []const u8) !Replayed {
    const fixture = try fixtureOf(arena, setup.driver.id, name);
    const replay = try arena.create(SocketReplay);
    replay.* = .init(arena, fixture.sockets);
    const http = try arena.create(foundation.replay.Replay);
    http.* = .init(arena, &.{});
    const made = try fixtures.over(arena, http.http(), try setup.options(arena, replay.connector()));
    replay.clock_ms = &made.host.clock_ms;
    return .{ .fixture = fixture, .models = made.models, .replay = replay };
}

/// What a session came to: its events, each copied out of the session, and the failure that ended it, where one did.
const Played = struct { events: []const ServerEvent, failure: ?Failure };

/// Opens the fixture's session, reads what it has, sends each of its events and reads what answers it, closes it,
/// and reads every event until it ends, or the session fails to open.
fn played(arena: Allocator, given: Replayed) !Played {
    const connected = if (given.fixture.request.object.contains("call_id"))
        try given.models.realtimeSideband(arena, try foundation.json.decodeValue(realtime.SidebandParams, arena, given.fixture.request))
    else
        try given.models.realtimeConnect(arena, try foundation.json.decodeValue(realtime.Session, arena, given.fixture.request));
    const session = switch (connected) {
        .session => |open| open,
        .failed => |failure| return .{ .events = &.{}, .failure = failure },
    };
    defer session.deinit();
    var events: std.ArrayList(ServerEvent) = .empty;
    try drain(arena, session, &events);
    for (given.fixture.events) |event| {
        session.send(event);
        try drain(arena, session, &events);
    }
    session.close();
    while (session.next()) |event| try events.append(arena, try copied(arena, event));
    if (given.replay.mismatch) |why| {
        std.debug.print("{s}\n", .{why});
        return error.TestUnexpectedMessage;
    }
    return .{ .events = events.items, .failure = if (session.failure()) |failure| try copiedFailure(arena, failure) else null };
}

/// Reads every event the session has now.
fn drain(arena: Allocator, session: *RealtimeSession, events: *std.ArrayList(ServerEvent)) !void {
    while (true) switch (session.poll(0)) {
        .event => |event| try events.append(arena, try copied(arena, event)),
        .quiet, .ended => return,
    };
}

/// `event`, which lives until the session's next read, copied into `a`.
fn copied(arena: Allocator, event: ServerEvent) !ServerEvent {
    return foundation.json.decode(ServerEvent, arena, try foundation.json.encode(arena, event));
}

fn copiedFailure(arena: Allocator, failure: Failure) !Failure {
    var made = failure;
    made.message = try arena.dupe(u8, failure.message);
    if (failure.code) |code| made.code = try arena.dupe(u8, code);
    return made;
}

/// What breaks a session's contract: a first event but `session.created`; an item's delta, partial text or segment
/// after its end; an end but one `completed`, carrying Octoii's account of its usage, or one `failed`; and, for a
/// session closed by `close()`, an item committed that never ended.
fn sessionProblems(arena: Allocator, events: []const ServerEvent, closed_by_client: bool) ![]const []const u8 {
    var problems: std.ArrayList([]const u8) = .empty;
    if (events.len == 0 or events[0] != .session_created) try problems.append(arena, "the session does not begin with session.created");
    var ended: std.StringHashMapUnmanaged(void) = .empty;
    var committed: std.StringHashMapUnmanaged(void) = .empty;
    for (events, 0..) |event, index| switch (event) {
        .committed => |of| try committed.put(arena, of.item_id, {}),
        .delta, .segment, .partial => if (ended.contains(event.itemId().?)) try problems.append(arena, try arena.print("event {d} comes after its item {s} ended", .{ index, event.itemId().? })),
        .completed, .failed => {
            const item = event.itemId().?;
            if (ended.contains(item)) try problems.append(arena, try arena.print("the item {s} ends twice, at event {d}", .{ item, index }));
            try ended.put(arena, item, {});
            if (event == .completed and (event.completed.octoii == null or event.completed.octoii.?.usage == null)) {
                try problems.append(arena, try arena.print("the item {s} completes without Octoii's account of its usage", .{item}));
            }
        },
        else => {},
    };
    if (closed_by_client) {
        var it = committed.keyIterator();
        while (it.next()) |item| if (!ended.contains(item.*)) try problems.append(arena, try arena.print("the item {s} was committed and never ended", .{item.*}));
    }
    return problems.items;
}

fn completions(arena: Allocator, events: []const ServerEvent) ![]const realtime.TranscriptionCompleted {
    var found: std.ArrayList(realtime.TranscriptionCompleted) = .empty;
    for (events) |event| if (event == .completed) try found.append(arena, event.completed);
    return found.items;
}

fn transcripts(arena: Allocator, events: []const ServerEvent) ![]const []const u8 {
    var found: std.ArrayList([]const u8) = .empty;
    for (try completions(arena, events)) |item| try found.append(arena, item.transcript);
    return found.items;
}

fn expectStrings(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| try std.testing.expectEqualStrings(want, got);
}

/// The first event of `tag` among `events`.
fn firstOf(events: []const ServerEvent, tag: std.meta.Tag(ServerEvent)) ?ServerEvent {
    for (events) |event| if (event == tag) return event;
    return null;
}

test "every recorded realtime session says what it is built from, opens as recorded with its key, and holds to the session contract" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    for ([_]Setup{ openai, deepgram, xai }) |setup| {
        for (try fixtures.mediaNames(arena, setup.driver.id, "realtime-transcription")) |name| {
            errdefer std.debug.print("{s}/{s}\n", .{ setup.driver.id, name });
            const given = try replayed(arena, setup, name);
            const session = try played(arena, given);
            try std.testing.expect(given.fixture.source.len > 0);
            if (session.events.len > 0) {
                const problems = try sessionProblems(arena, session.events, session.failure == null);
                for (problems) |problem| std.debug.print("session contract: {s}\n", .{problem});
                try std.testing.expectEqual(@as(usize, 0), problems.len);
            }
            try std.testing.expectEqual(@as(usize, 0), given.replay.unplayed());
            for (given.replay.opened.items) |opened| try std.testing.expectEqualStrings(setup.authorization, foundation.http.find(opened.headers, "authorization").?);
        }
    }
}

test "OpenAI opens a session by its model's id, gives the session by its reference, and prices each item at the model's prices" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const session = try played(arena, try replayed(arena, openai, "realtime-transcription"));
    try std.testing.expectEqual(null, session.failure);
    try std.testing.expect(session.events[0] == .session_created and session.events[1] == .session_updated);
    try std.testing.expect(std.mem.indexOf(u8, session.events[1].session_updated.session.text, "\"model\":\"openai/gpt-live-transcribe\"") != null);
    try expectStrings(&.{ "Hello, how are you?", "About AC-42." }, try transcripts(arena, session.events));
    const first = (try completions(arena, session.events))[0].octoii.?.usage.?;
    try std.testing.expectEqual(@as(?f64, 0.2), first.seconds);
    try std.testing.expectApproxEqAbs(0.2 * 0.017 / 60.0, first.cost.?, 1e-12);
    // The audio left as it closed is committed, and the session ends once that item completes.
    const last = session.events[session.events.len - 1];
    try std.testing.expectEqualStrings("item_004", last.completed.item_id);
}

test "OpenAI's refusal of a session's settings fails it to open, classified by its type" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const failure = (try played(arena, try replayed(arena, openai, "realtime-refused"))).failure.?;
    try std.testing.expectEqual(.invalid_request, failure.kind);
    try std.testing.expectEqualStrings("invalid_value", failure.code.?);
}

test "OpenAI connects as a call's sideband, which sends no audio" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const given = try replayed(arena, openai, "realtime-sideband");
    const session = (try given.models.realtimeSideband(arena, try foundation.json.decodeValue(realtime.SidebandParams, arena, given.fixture.request))).session;
    defer session.deinit();
    var events: std.ArrayList(ServerEvent) = .empty;
    try drain(arena, session, &events);
    session.send(.{ .append = .{ .audio = "AAAA" } });
    session.close();
    while (session.next()) |event| try events.append(arena, try copied(arena, event));
    try std.testing.expectEqual(.invalid_request, firstOf(events.items, .@"error").?.@"error".@"error".octoii.kind);
    try expectStrings(&.{"Call me back."}, try transcripts(arena, events.items));
}

test "OpenAI makes a session for a client by WebRTC: the answer and its call's id" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const fixture = try fixtureOf(arena, "openai", "realtime-call");
    const http = try arena.create(foundation.replay.Replay);
    http.* = .init(arena, fixture.exchanges);
    const models = try fixtures.modelsOver(arena, http.http(), .{ .driver = openai.driver, .key = openai.key, .models = try host_models.openai(arena) });
    const made = (try models.realtimeCreateCall(arena, try foundation.json.decodeValue(realtime.CallCreateParams, arena, fixture.request))).made;
    try std.testing.expectEqualStrings("rtc_u1_9c6574da8b8a41a18da9308f4ad974ce", made.call_id);
    try std.testing.expect(std.mem.startsWith(u8, made.sdp, "v=0\r\n"));
    try std.testing.expectEqualStrings("Bearer sk-test", foundation.http.find(http.sent.items[0].headers, "authorization").?);
    try std.testing.expectEqual(@as(usize, 0), http.unused().len);
}

/// `Models` over `setup`'s provider whose one socket a test plays by hand.
const ByHand = struct { models: *Models, socket: *Scripted };

fn byHand(arena: Allocator, setup: Setup) !ByHand {
    const socket = try arena.create(Scripted);
    const http = try arena.create(foundation.replay.Replay);
    http.* = .init(arena, &.{});
    const made = try fixtures.over(arena, http.http(), try setup.options(arena, undefined));
    socket.* = .init(arena, &made.host.clock_ms);
    made.models.host.connector = socket.connector();
    return .{ .models = made.models, .socket = socket };
}

fn sessionOf(arena: Allocator, json: []const u8) !realtime.Session {
    return foundation.json.decode(realtime.Session, arena, json);
}

test "OpenAI answers a session.update that names another model with an error event, and sends it not" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const given = try byHand(arena, openai);
    try given.socket.give("{\"type\":\"session.created\",\"event_id\":\"e1\",\"session\":{\"type\":\"transcription\"}}");
    try given.socket.give("{\"type\":\"session.updated\",\"event_id\":\"e2\",\"session\":{\"type\":\"transcription\"}}");
    const session = (try given.models.realtimeConnect(arena, try sessionOf(arena, "{\"type\":\"transcription\",\"audio\":{\"input\":{\"transcription\":{\"model\":\"openai/gpt-live-transcribe\"},\"turn_detection\":null}}}"))).session;
    defer session.deinit();
    session.send(.{ .session_update = .{ .session = try sessionOf(arena, "{\"type\":\"transcription\",\"audio\":{\"input\":{\"transcription\":{\"model\":\"openai/gpt-transcribe\"}}}}") } });
    session.close();
    var events: std.ArrayList(ServerEvent) = .empty;
    while (session.next()) |event| try events.append(arena, try copied(arena, event));
    try std.testing.expectEqual(@as(usize, 1), given.socket.sent.items.len);
    try std.testing.expectEqual(.invalid_request, events.items[events.items.len - 1].@"error".@"error".octoii.kind);
}

test "Deepgram's results become items: partial text, settled text, speakers, speech heard, and each item's seconds at its stream's prices" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const session = try played(arena, try replayed(arena, deepgram, "realtime-transcription"));
    try std.testing.expectEqual(null, session.failure);
    const partial = firstOf(session.events, .partial).?.partial;
    try std.testing.expectEqualStrings("take met", partial.text);
    try std.testing.expectEqualStrings("item_1", partial.item_id);
    var segments: std.ArrayList(realtime.TranscriptionSegment) = .empty;
    for (session.events) |event| if (event == .segment) try segments.append(arena, event.segment);
    try std.testing.expectEqual(@as(usize, 2), segments.items.len);
    try std.testing.expectEqualStrings("Take metformin daily.", segments.items[0].text);
    try std.testing.expectEqualStrings("0", segments.items[0].speaker);
    try std.testing.expectEqual(@as(f64, 0.02), segments.items[0].start);
    try std.testing.expectEqual(@as(f64, 0.2), segments.items[0].end);
    try std.testing.expectEqualStrings("And atorvastatin?", segments.items[1].text);
    try std.testing.expectEqualStrings("1", segments.items[1].speaker);
    try std.testing.expectEqual(@as(u64, 20), firstOf(session.events, .speech_started).?.speech_started.audio_start_ms);
    const stopped = firstOf(session.events, .speech_stopped).?.speech_stopped;
    try std.testing.expectEqual(@as(u64, 300), stopped.audio_end_ms);
    try std.testing.expectEqualStrings("item_2", stopped.item_id);
    const items = try completions(arena, session.events);
    try expectStrings(&.{ "Take metformin daily.", "And atorvastatin?" }, try transcripts(arena, session.events));
    try std.testing.expectEqual(@as(f64, 0.2), items[0].usage.duration.seconds);
    try std.testing.expectEqual(@as(f64, 0.1), items[1].usage.duration.seconds);
    try std.testing.expectApproxEqAbs(0.1 * 0.0077 / 60.0, items[1].octoii.?.usage.?.cost.?, 1e-12);
}

test "Deepgram's session fails as transport when its connection ends unasked" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    try std.testing.expectEqual(.transport, (try played(arena, try replayed(arena, deepgram, "realtime-closed"))).failure.?.kind);
}

test "Deepgram's silent connection is kept open with KeepAlive" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const given = try byHand(arena, deepgram);
    const session = (try given.models.realtimeConnect(arena, try sessionOf(arena, "{\"type\":\"transcription\",\"audio\":{\"input\":{\"transcription\":{\"model\":\"deepgram/nova-3\"}}}}"))).session;
    defer session.deinit();
    try std.testing.expectEqual(.session_created, std.meta.activeTag(session.poll(0).event));
    try std.testing.expectEqual(.quiet, std.meta.activeTag(session.poll(session_.keep_alive_ms)));
    try expectStrings(&.{"{\"type\":\"KeepAlive\"}"}, given.socket.sent.items);
}

test "Deepgram answers a session.update that changes nothing as updated, and one that changes a setting with an error event" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const given = try byHand(arena, deepgram);
    const settings = "{\"type\":\"transcription\",\"audio\":{\"input\":{\"transcription\":{\"model\":\"deepgram/nova-3\",\"language\":\"en\"}}}}";
    const session = (try given.models.realtimeConnect(arena, try sessionOf(arena, settings))).session;
    defer session.deinit();
    session.send(.{ .session_update = .{ .session = try sessionOf(arena, settings) } });
    session.send(.{ .session_update = .{ .session = try sessionOf(arena, "{\"type\":\"transcription\",\"audio\":{\"input\":{\"transcription\":{\"model\":\"deepgram/nova-3\",\"language\":\"fr\"}}}}") } });
    given.socket.end();
    var tags: std.ArrayList(std.meta.Tag(ServerEvent)) = .empty;
    while (session.next()) |event| try tags.append(arena, event);
    try std.testing.expectEqualSlices(std.meta.Tag(ServerEvent), &.{ .session_created, .session_updated, .@"error" }, tags.items);
    try std.testing.expectEqual(.invalid_request, session.failure().?.kind);
}

test "Deepgram's session fails before connecting for a setting its stream does not take" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const given = try byHand(arena, deepgram);
    const failed = (try given.models.realtimeConnect(arena, try sessionOf(arena, "{\"type\":\"transcription\",\"audio\":{\"input\":{\"transcription\":{\"model\":\"deepgram/nova-3\",\"prompt\":\"A pharmacy call.\"}}}}"))).failed;
    try std.testing.expectEqual(.invalid_request, failed.kind);
    try std.testing.expectEqual(null, given.socket.url);
}

test "xAI opens once its stream is ready, settles what follows the utterance's settled text, and ends an item at a commit and at its end" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const session = try played(arena, try replayed(arena, xai, "realtime-transcription"));
    try std.testing.expectEqual(null, session.failure);
    var deltas: std.ArrayList([]const u8) = .empty;
    for (session.events) |event| if (event == .delta) try deltas.append(arena, event.delta.delta.?);
    try expectStrings(&.{ "I will buy two", " of those, please.", "Thanks." }, deltas.items);
    const items = try completions(arena, session.events);
    try expectStrings(&.{ "I will buy two of those, please.", "Thanks." }, try transcripts(arena, session.events));
    try std.testing.expectEqual(@as(f64, 0.2), items[0].usage.duration.seconds);
    try std.testing.expectEqual(@as(f64, 0.1), items[1].usage.duration.seconds);
    try std.testing.expectApproxEqAbs(0.2 * 0.2 / 3600.0, items[0].octoii.?.usage.?.cost.?, 1e-12);
}

test "xAI's session fails as the error it sent before it closed" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const failure = (try played(arena, try replayed(arena, xai, "realtime-failed"))).failure.?;
    try std.testing.expectEqual(.server, failure.kind);
    try std.testing.expectEqualStrings("The transcription pipeline failed", failure.message);
}

test "xAI's session fails before connecting for several languages, as it takes one" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const given = try byHand(arena, xai);
    const failed = (try given.models.realtimeConnect(arena, try sessionOf(arena, "{\"type\":\"transcription\",\"audio\":{\"input\":{\"transcription\":{\"model\":\"xai/grok-voice-transcribe-2.0\",\"languages\":[\"en\",\"fr\"]}}}}"))).failed;
    try std.testing.expectEqual(.invalid_request, failed.kind);
    try std.testing.expectEqual(null, given.socket.url);
}

test "a session fails before anything is sent for a model of another kind" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const given = try byHand(arena, deepgram);
    const failed = (try given.models.realtimeConnect(arena, try sessionOf(arena, "{\"type\":\"transcription\",\"audio\":{\"input\":{\"transcription\":{\"model\":\"deepgram/nova-3-pharma\"}}}}"))).failed;
    try std.testing.expect(std.mem.indexOf(u8, failed.message, "does not serve realtime-transcription") != null);
    try std.testing.expectEqual(null, given.socket.url);
}

test "a session fails as timeout where its provider takes no settings in time, its socket closed" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const given = try byHand(arena, openai);
    const failed = (try given.models.realtimeConnect(arena, try sessionOf(arena, "{\"type\":\"transcription\",\"audio\":{\"input\":{\"transcription\":{\"model\":\"openai/gpt-live-transcribe\"}}}}"))).failed;
    try std.testing.expectEqual(.timeout, failed.kind);
    try std.testing.expect(given.socket.closed);
}

test "a session ends as timeout where the items committed do not complete in time after its close" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const given = try byHand(arena, openai);
    try given.socket.give("{\"type\":\"session.updated\",\"event_id\":\"e1\",\"session\":{\"type\":\"transcription\"}}");
    const session = (try given.models.realtimeConnect(arena, try sessionOf(arena, "{\"type\":\"transcription\",\"audio\":{\"input\":{\"transcription\":{\"model\":\"openai/gpt-live-transcribe\"}}}}"))).session;
    defer session.deinit();
    session.send(.{ .append = .{ .audio = "AAAA" } });
    session.close();
    while (session.next()) |_| {}
    try std.testing.expectEqual(.timeout, session.failure().?.kind);
    try std.testing.expect(given.socket.closed);
}
