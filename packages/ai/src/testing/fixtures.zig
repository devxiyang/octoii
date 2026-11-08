//! The recorded exchanges each driver is tested against, under `test/fixtures/<provider>/<name>.json`: the request in
//! the vocabulary, and each HTTP exchange it made — the request sent and the response's status, headers and chunks.
//! A fixture is replayed through the real `Models`: what is sent must be what was recorded.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const Replay = foundation.replay.Replay;
const vocabulary = @import("vocabulary");
const Event = vocabulary.ResponseStreamEvent;
const seam = @import("../driver.zig");
const Models = @import("../Models.zig");
const Host = @import("host.zig").Host;
const contract = @import("contract.zig");

pub const Fixture = struct {
    /// What the fixture was built from.
    source: []const u8,
    request: vocabulary.ResponsesRequest,
    exchanges: []const foundation.replay.Exchange,
};

/// The bytes of the fixture `name` of `provider`'s; read from the package's folder, where tests run.
fn bytesOf(arena: Allocator, provider: []const u8, name: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(arena, "test/fixtures/{s}/{s}.json", .{ provider, name });
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, .limited(16 << 20));
}

/// The text fixture `name` of `provider`'s.
pub fn load(arena: Allocator, provider: []const u8, name: []const u8) !Fixture {
    return foundation.json.decode(Fixture, arena, try bytesOf(arena, provider, name));
}

/// The names of `provider`'s text fixtures, in order: those of no other kind.
pub fn textNames(arena: Allocator, provider: []const u8) ![]const []const u8 {
    const folder = try std.fmt.allocPrint(arena, "test/fixtures/{s}", .{provider});
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, folder, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const name = try arena.dupe(u8, entry.name[0 .. entry.name.len - ".json".len]);
        const kind = try foundation.json.decode(struct { kind: ?[]const u8 = null }, arena, try bytesOf(arena, provider, name));
        if (kind.kind == null) try names.append(arena, name);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return names.items;
}

/// A fixture streamed: its events, its last response, and the replay, which holds what was sent.
pub const Streamed = struct {
    events: []const Event,
    response: vocabulary.Response,
    replay: *Replay,
};

/// How a fixture is streamed: through which driver, with which key, and the provider's models and settings.
pub const Options = struct {
    driver: *const seam.Driver,
    /// The provider's id; the driver's own unless given.
    provider: ?[]const u8 = null,
    /// The folder its fixtures are in; the provider's id unless given.
    folder: ?[]const u8 = null,
    key: ?[]const u8 = "test-key",
    /// The provider's credential other than a key, such as a sign-in.
    credential: ?seam.Credential = null,
    /// The host's stored files.
    stored: @FieldType(Host, "stored") = &.{},
    models: []const @import("../catalogue/facts.zig").ModelFacts = &.{},
    settings: seam.Settings = .{},
    /// The host's WebSocket; the standard library's, unless given.
    connector: ?foundation.websocket.Connector = null,
    /// When the requests are sent.
    now_ms: i64 = @import("host.zig").now_ms,
};

/// The host a fixture is streamed through: its clock, its key and its credential for the provider `id`.
fn hostOf(arena: Allocator, id: []const u8, options: Options) Allocator.Error!Host {
    const Key = @typeInfo(@FieldType(Host, "keys")).pointer.child;
    return .{
        .clock_ms = options.now_ms,
        .keys = if (options.key) |key| try arena.dupe(Key, &.{.{ .provider = id, .key = key }}) else &.{},
        .saved = if (options.credential) |credential| .{ .provider = id, .credential = credential } else null,
        .stored = options.stored,
    };
}

/// `Models` over the driver's one provider, as `options` set it, its HTTP `http`.
pub fn modelsOver(arena: Allocator, http: foundation.http.Http, options: Options) !*Models {
    return (try over(arena, http, options)).models;
}

/// `Models` and the test host it runs on, whose clock a test moves.
pub const Over = struct { models: *Models, host: *Host };

/// `Models` over the driver's one provider, as `options` set it, its HTTP `http`, and the host it runs on.
pub fn over(arena: Allocator, http: foundation.http.Http, options: Options) !Over {
    const id = options.provider orelse options.driver.id;
    const host = try arena.create(Host);
    host.* = try hostOf(arena, id, options);
    const providers = try arena.dupe(seam.Provider, &.{.{ .id = id, .name = id, .driver = options.driver, .settings = options.settings, .models = options.models }});
    var given = host.host(http);
    given.connector = options.connector;
    return .{ .models = try Models.init(arena, .{ .providers = providers, .host = given }), .host = host };
}

/// `request` streamed through `Models` over the driver, its HTTP answered from `exchanges`; the stream held to the
/// stream's contract.
pub fn stream(arena: Allocator, request: vocabulary.ResponsesRequest, exchanges: []const foundation.replay.Exchange, options: Options) !Streamed {
    const replay = try arena.create(Replay);
    replay.* = .init(arena, exchanges);
    const models = try modelsOver(arena, replay.http(), options);
    var text = models.text(arena, request);
    defer text.close();
    var events: std.ArrayList(Event) = .empty;
    while (try text.next()) |event| try events.append(arena, event);
    const problems = try contract.problems(arena, events.items);
    for (problems) |problem| std.debug.print("stream contract: {s}\n", .{problem});
    try std.testing.expectEqual(@as(usize, 0), problems.len);
    return .{ .events = events.items, .response = text.response().?, .replay = replay };
}

/// The fixture `name` of the driver's provider, streamed as recorded: every exchange asked for, none refused.
pub fn streamFixture(arena: Allocator, name: []const u8, options: Options) !Streamed {
    const fixture = try load(arena, options.folder orelse options.provider orelse options.driver.id, name);
    const streamed = try stream(arena, fixture.request, fixture.exchanges, options);
    if (streamed.replay.mismatch) |why| {
        std.debug.print("fixture {s}: {s}\n", .{ name, why });
        return error.TestUnexpectedRequest;
    }
    try std.testing.expectEqual(@as(usize, 0), streamed.replay.unused().len);
    return streamed;
}

/// The text of the first message in `output`.
pub fn messageText(arena: Allocator, output: []const vocabulary.OutputItem) !?[]const u8 {
    for (output) |item| if (item == .output_message) switch (item.output_message.content) {
        .text => |whole| return whole,
        .parts => |parts| {
            var joined: std.ArrayList(u8) = .empty;
            for (parts) |part| if (part == .output_text) try joined.appendSlice(arena, part.output_text.text);
            return joined.items;
        },
    };
    return null;
}

/// The body of the request sent `index`th, read as JSON.
pub fn sentBody(arena: Allocator, replay: *const Replay, index: usize) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, replay.sent.items[index].body.?, .{});
}

/// Whether `value` holds `key` as a key, or `key` as a type, at any depth.
pub fn holds(value: std.json.Value, key: []const u8) bool {
    switch (value) {
        .array => |list| for (list.items) |entry| if (holds(entry, key)) return true,
        .object => |members| {
            var it = members.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, key)) return true;
                if (std.mem.eql(u8, entry.key_ptr.*, "type") and entry.value_ptr.* == .string and std.mem.eql(u8, entry.value_ptr.string, key)) return true;
                if (holds(entry.value_ptr.*, key)) return true;
            }
        },
        else => {},
    }
    return false;
}

/// A host's HTTP that answers every request with the same streamed body, and a file server's address with a text
/// file, keeping each request sent: for tests that read what a request becomes on the wire.
pub const Answering = struct {
    arena: Allocator,
    chunks: []const []const u8,
    status: u16 = 200,
    content_type: []const u8 = "text/event-stream",
    sent: std.ArrayList(foundation.http.Request) = .empty,

    pub fn http(answering: *Answering) foundation.http.Http {
        return .{ .context = answering, .vtable = &.{ .send = send } };
    }

    fn send(context: *anyopaque, request: foundation.http.Request) foundation.http.SendError!foundation.http.Response {
        const answering: *Answering = @ptrCast(@alignCast(context));
        const arena = answering.arena;
        try answering.sent.append(arena, .{ .method = request.method, .url = try arena.dupe(u8, request.url), .headers = try arena.dupe(foundation.http.Header, request.headers), .body = if (request.body) |body| try arena.dupe(u8, body) else null });
        const file = std.mem.startsWith(u8, request.url, "https://files.example.com/");
        const chunks: []const []const u8 = if (file) &.{"Paris: 18 \u{b0}C"} else answering.chunks;
        const body = try arena.create(foundation.replay.ChunkReader);
        body.* = .init(chunks, try arena.alloc(u8, 4096));
        const headers = try arena.dupe(foundation.http.Header, &.{.{ .name = "content-type", .value = if (file) "text/plain" else answering.content_type }});
        return .{ .status = if (file) 200 else answering.status, .headers = headers, .body = &body.reader, .context = body, .vtable = &.{ .failure = failure, .close = close } };
    }

    fn failure(_: *anyopaque) foundation.http.Error {
        return error.Transport;
    }

    fn close(_: *anyopaque) void {}
};

/// What `request` sends through the driver when every request is answered with `chunks`: the stream as it ended,
/// and the requests sent.
pub fn answered(arena: Allocator, request: vocabulary.ResponsesRequest, chunks: []const []const u8, options: Options) !Answered {
    return answeredWith(arena, request, .{ .arena = arena, .chunks = chunks }, options);
}

pub const Answered = struct { response: vocabulary.Response, sent: []const foundation.http.Request };

/// What `request` sends through the driver when every request is answered as `answering` says.
pub fn answeredWith(arena: Allocator, request: vocabulary.ResponsesRequest, given: Answering, options: Options) !Answered {
    const answering = try arena.create(Answering);
    answering.* = given;
    const models = try modelsOver(arena, answering.http(), options);
    const response = try models.create(arena, request);
    return .{ .response = response, .sent = answering.sent.items };
}

/// Expects `actual` to count what `expected` counts, meter by meter, and to cost what it costs, to within a billionth
/// of a cent.
/// That `id` is one the mint gave: a UUID of version 7, as text.
pub fn expectMinted(id: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 36), id.len);
    try std.testing.expectEqual(@as(u8, '7'), id[14]);
}

pub fn expectUsage(expected: vocabulary.Usage, actual: vocabulary.Usage) !void {
    var meters = actual;
    meters.cost = expected.cost;
    try std.testing.expectEqual(expected, meters);
    if (expected.cost) |cost| try std.testing.expectApproxEqAbs(cost, actual.cost.?, 1e-12);
}

/// The bundled catalogue's model `id` of `provider`.
pub fn catalogueModel(arena: Allocator, provider: []const u8, id: []const u8) !@import("../catalogue/model.zig").Model {
    for (try @import("../catalogue/catalogue.zig").bundled(arena)) |model| {
        if (std.mem.eql(u8, model.octoii.provider, provider) and std.mem.eql(u8, model.id, id)) return model;
    }
    return error.NotInCatalogue;
}

/// A request read from its JSON.
pub fn decoded(arena: Allocator, given: []const u8) !vocabulary.ResponsesRequest {
    return foundation.json.decode(vocabulary.ResponsesRequest, arena, given);
}

/// Expects `actual` to be the JSON `expected` is, whatever its members' order.
pub fn expectJson(arena: Allocator, expected: []const u8, actual: []const u8) !void {
    const left = try std.json.parseFromSliceLeaky(std.json.Value, arena, expected, .{});
    const right = try std.json.parseFromSliceLeaky(std.json.Value, arena, actual, .{});
    if (!foundation.json.equal(left, right)) {
        std.debug.print("expected {s}\n   found {s}\n", .{ expected, actual });
        return error.TestExpectedEqual;
    }
}

/// A request to `model` of "Hi" and `fields`, which may give its input in place of "Hi".
pub fn requestWith(arena: Allocator, model: []const u8, fields: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, fields, "\"input\":") != null) return std.fmt.allocPrint(arena, "{{\"model\":\"{s}\",{s}}}", .{ model, fields });
    return std.fmt.allocPrint(arena, "{{\"model\":\"{s}\",\"input\":\"Hi\",{s}}}", .{ model, fields });
}

/// The failure the fixture `name` ends its response with.
pub fn failureOf(arena: Allocator, name: []const u8, options: Options) !vocabulary.response.ResponseError {
    const streamed = try streamFixture(arena, name, options);
    try std.testing.expectEqual(vocabulary.response.ResponseStatus.failed, streamed.response.status);
    return streamed.response.@"error".?;
}

/// The failure the request `given` ends with before anything is sent.
pub fn refusal(arena: Allocator, given: []const u8, options: Options) !vocabulary.response.ResponseError {
    const streamed = try stream(arena, try decoded(arena, given), &.{}, options);
    try std.testing.expectEqual(@as(usize, 0), streamed.replay.sent.items.len);
    return streamed.response.@"error".?;
}

/// A fixture of a kind other than text: its request of the kind's vocabulary.
pub fn MediaFixture(comptime Request: type) type {
    return struct { source: []const u8, kind: []const u8, request: Request, exchanges: []const foundation.replay.Exchange };
}

/// The names of `provider`'s fixtures of `kind`, in order.
pub fn mediaNames(arena: Allocator, provider: []const u8, kind: []const u8) ![]const []const u8 {
    const folder = try std.fmt.allocPrint(arena, "test/fixtures/{s}", .{provider});
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, folder, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const name = try arena.dupe(u8, entry.name[0 .. entry.name.len - ".json".len]);
        const given = try foundation.json.decode(struct { kind: ?[]const u8 = null }, arena, try bytesOf(arena, provider, name));
        if (given.kind) |named| if (std.mem.eql(u8, named, kind)) try names.append(arena, name);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return names.items;
}

/// A media fixture streamed: its events, the failure it ended with, and the replay.
pub fn MediaStreamed(comptime Made: type) type {
    return struct { events: []const Made, failure: ?@import("../failure.zig").Failure, replay: *Replay };
}

/// The fixture `name` of the driver's provider, of `Request`, streamed through `start` as recorded: every exchange
/// asked for, none refused, the stream ended with its last event or an `error`.
fn streamedMedia(comptime Request: type, comptime Made: type, comptime start: anytype, arena: Allocator, name: []const u8, options: Options) !MediaStreamed(Made) {
    const fixture = try foundation.json.decode(MediaFixture(Request), arena, try bytesOf(arena, options.folder orelse options.provider orelse options.driver.id, name));
    const replay = try arena.create(Replay);
    replay.* = .init(arena, fixture.exchanges);
    const models = try modelsOver(arena, replay.http(), options);
    var made = start(models, arena, fixture.request);
    defer made.close();
    var events: std.ArrayList(Made) = .empty;
    while (try made.next()) |event| try events.append(arena, event);
    if (replay.mismatch) |why| {
        std.debug.print("fixture {s}: {s}\n", .{ name, why });
        return error.TestUnexpectedRequest;
    }
    try std.testing.expectEqual(@as(usize, 0), replay.unused().len);
    return .{ .events = events.items, .failure = made.failure, .replay = replay };
}

/// The image fixture `name`, streamed as recorded.
pub fn images(arena: Allocator, name: []const u8, options: Options) !MediaStreamed(vocabulary.images.ImageStreamEvent) {
    return streamedMedia(vocabulary.images.ImageRequest, vocabulary.images.ImageStreamEvent, Models.imageStream, arena, name, options);
}

/// The speech fixture `name`, streamed as recorded.
pub fn speech(arena: Allocator, name: []const u8, options: Options) !MediaStreamed(vocabulary.speech.SpeechStreamEvent) {
    return streamedMedia(vocabulary.speech.SpeechRequest, vocabulary.speech.SpeechStreamEvent, Models.speechStream, arena, name, options);
}

/// The transcription fixture `name`, streamed as recorded.
pub fn transcriptions(arena: Allocator, name: []const u8, options: Options) !MediaStreamed(vocabulary.transcriptions.TranscriptionStreamEvent) {
    return streamedMedia(vocabulary.transcriptions.TranscriptionRequest, vocabulary.transcriptions.TranscriptionStreamEvent, Models.transcriptionStream, arena, name, options);
}

/// What the fixture `name`, of `Request`, makes whole through `create`, its exchanges replayed: what it made, or the
/// failure it ended with.
pub fn created(comptime Request: type, comptime create: anytype, arena: Allocator, name: []const u8, options: Options) !@typeInfo(@typeInfo(@TypeOf(create)).@"fn".return_type.?).error_union.payload {
    const fixture = try foundation.json.decode(MediaFixture(Request), arena, try bytesOf(arena, options.folder orelse options.provider orelse options.driver.id, name));
    const replay = try arena.create(Replay);
    replay.* = .init(arena, fixture.exchanges);
    const models = try modelsOver(arena, replay.http(), options);
    return create(models, arena, fixture.request);
}
