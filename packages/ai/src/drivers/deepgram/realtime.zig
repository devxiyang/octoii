//! Deepgram's realtime transcription: its live streaming API at the WebSocket `/listen`, every setting in the query and
//! the audio as binary frames. Its results become the items its stream has none of: a result not final is the item's
//! partial text, a final one its delta, and one that ends speech, or that a `Finalize` asked for, ends the item. A commit
//! is `Finalize`, `close()` is `CloseStream`, and a silent connection is kept open with `KeepAlive`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const oauth = foundation.oauth;
const vocabulary = @import("vocabulary");
const realtime = vocabulary.realtime;
const seam = @import("../../driver.zig");
const Call = seam.Call;
const Error = @import("../../failure.zig").Error;
const Model = @import("../../catalogue/model.zig").Model;
const json = @import("../../wire/json.zig");
const query_ = @import("../../wire/query.zig");
const session_ = @import("../../wire/realtime/session.zig");
const Out = session_.Out;
const WireError = session_.Error;
const items_ = @import("../../wire/realtime/items.zig");
const Refusal = items_.Refusal;
const deepgram = @import("../deepgram.zig");

/// The messages Deepgram's stream takes besides audio.
const finalize = "{\"type\":\"Finalize\"}";
const close_stream = "{\"type\":\"CloseStream\"}";
const keep_alive = "{\"type\":\"KeepAlive\"}";

pub const calls: seam.RealtimeCalls = .{ .connect = connect };

/// The query a session goes to Deepgram's stream with: the model by its id, the audio's format, smart formatting and
/// interim results, its languages, keyterms and turn detection, and Deepgram's own options; `Refused` for a setting
/// Deepgram does not take.
pub fn liveQuery(arena: Allocator, refusal: *Refusal, model_id: []const u8, session: *const realtime.Session) Refusal.Error![]const u8 {
    try items_.checkStreamSettings(arena, refusal, "Deepgram", session);
    const input = &session.audio.input;
    var fields: std.ArrayList(oauth.Field) = .empty;
    try fields.appendSlice(arena, &.{
        .{ "model", model_id }, .{ "encoding", "linear16" }, .{ "sample_rate", "24000" },
        .{ "channels", "1" },   .{ "smart_format", "true" }, .{ "interim_results", "true" },
    });
    // One language as it is, several as `multi` with each a hint, none as Deepgram's own.
    const languages = session.languages();
    if (languages.len <= 1) {
        for (languages) |language| try fields.append(arena, .{ "language", language });
    } else {
        try fields.append(arena, .{ "language", "multi" });
        for (languages) |language| try fields.append(arena, .{ "language_hint", language });
    }
    for (input.transcription.keywords orelse &.{}) |keyword| try fields.append(arena, .{ "keyterm", keyword });
    // Turn detection off is no endpointing; else speech events, with the silence that ends speech.
    if (input.turn_detection != null and input.turn_detection.? == .null) {
        try fields.append(arena, .{ "endpointing", "false" });
    } else {
        try fields.append(arena, .{ "vad_events", "true" });
        const turn = if (input.turn_detection) |given| given.given() else null;
        if (turn) |detection| if (detection.silence_duration_ms) |silence| try fields.append(arena, .{ "endpointing", try std.fmt.allocPrint(arena, "{d}", .{silence}) });
    }
    const options = if (session.provider) |provider| try json.optionsOf(arena, provider.options, "deepgram") else null;
    if (try query_.appendOptions(arena, &fields, options)) |name| {
        return refusal.refuse(arena, "Deepgram's option {s} is a parameter of its query, which takes text, numbers and booleans", .{name});
    }
    return oauth.formEncoded(arena, fields.items);
}

fn connect(call: *Call, model: *const Model, session: *const realtime.Session, gpa: Allocator) Error!seam.RealtimeOpening {
    var refusal: Refusal = .{};
    const query = liveQuery(call.arena, &refusal, model.id, session) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Refused => return call.failWith(.invalid_request, "{s}", .{refusal.message.?}),
    };
    const key = try call.apiKey();
    const wire = try Wire.create(gpa, .{
        .reference = try model.reference(call.arena),
        .model_id = model.id,
        .state = (try items_.sessionState(call.arena, session)).text,
        .query = query,
        .ends_at_speech = !(session.audio.input.turn_detection != null and session.audio.input.turn_detection.? == .null),
    });
    return .{
        .url = try session_.socketUrl(call.arena, call.baseUrl(deepgram.base_url), "/listen", query),
        .headers = try call.arena.dupe(foundation.http.Header, &.{.{ .name = "authorization", .value = try std.fmt.allocPrint(call.arena, "Token {s}", .{key}) }}),
        .wire = wire.wire(),
    };
}

/// What a session's wire keeps of how it connected.
const Connected = struct {
    reference: []const u8,
    model_id: []const u8,
    /// The session's settings, as its events give them.
    state: []const u8,
    query: []const u8,
    ends_at_speech: bool,
};

/// How a session speaks over Deepgram's stream.
const Wire = struct {
    gpa: Allocator,
    strings: std.heap.ArenaAllocator,
    connected: Connected,
    ids: session_.Ids = .{},
    items: items_.HeardItems,

    fn create(gpa: Allocator, connected: Connected) Allocator.Error!*Wire {
        const made = try gpa.create(Wire);
        errdefer gpa.destroy(made);
        made.* = .{ .gpa = gpa, .strings = .init(gpa), .connected = undefined, .items = undefined };
        errdefer made.strings.deinit();
        const strings = made.strings.allocator();
        made.connected = .{
            .reference = try strings.dupe(u8, connected.reference),
            .model_id = try strings.dupe(u8, connected.model_id),
            .state = try strings.dupe(u8, connected.state),
            .query = try strings.dupe(u8, connected.query),
            .ends_at_speech = connected.ends_at_speech,
        };
        made.items = .init(gpa, &made.ids);
        return made;
    }

    fn wire(self: *Wire) session_.Wire {
        return .{
            .context = self,
            .vtable = &.{ .start = start, .read = read, .write = write, .close = close, .settled = settled, .ended = ended, .deinit = deinit },
            .keep_alive = .{ .text = keep_alive },
        };
    }

    fn of(context: *anyopaque) *Wire {
        return @ptrCast(@alignCast(context));
    }

    fn start(context: *anyopaque, out: *Out) WireError!void {
        const self = of(context);
        try out.give(.{ .session_created = .{ .session = .{ .text = self.connected.state }, .event_id = try self.ids.event(out.arena) } });
    }

    fn read(context: *anyopaque, out: *Out, message: foundation.websocket.Message) WireError!void {
        const self = of(context);
        const text = switch (message) {
            .text => |given| given,
            .binary => return out.brokenBy("Deepgram sent a message that is no JSON event", .{}),
        };
        const value = std.json.parseFromSliceLeaky(std.json.Value, out.arena, text, .{ .allocate = .alloc_always }) catch return out.brokenBy("Deepgram sent a message that is no JSON event", .{});
        const kind = json.textOf(value, "type") orelse return out.brokenBy("Deepgram sent a message that is no JSON event", .{});
        if (std.mem.eql(u8, kind, "Results")) {
            const result = foundation.json.decodeValue(Results, out.arena, value) catch return;
            return self.resultEvents(out, result);
        }
        if (std.mem.eql(u8, kind, "SpeechStarted")) {
            const started = foundation.json.decodeValue(struct { timestamp: f64 }, out.arena, value) catch return;
            return self.items.speechStarted(out, started.timestamp);
        }
        if (std.mem.eql(u8, kind, "Error")) {
            const said = foundation.json.decodeValue(struct { variant: ?[]const u8 = null, description: ?[]const u8 = null }, out.arena, value) catch return;
            const failed = session_.realtimeError(.invalid_request, said.description orelse "Deepgram could not take a message", said.variant);
            return out.give(.{ .@"error" = .{ .@"error" = failed, .event_id = try self.ids.event(out.arena) } });
        }
        // Its other messages, such as its metadata, say nothing the vocabulary holds.
    }

    /// The events of a result: its partial or settled text, its speakers, and the item it ends.
    fn resultEvents(self: *Wire, out: *Out, result: Results) Allocator.Error!void {
        const items = &self.items;
        if (items.isCleared(result.start, result.duration)) return;
        const alternative = if (result.channel.alternatives.len > 0) result.channel.alternatives[0] else null;
        const text = if (alternative) |given| given.transcript else "";
        if (result.is_final != true) return if (text.len > 0) items.heard(out, text);
        const given_words = if (alternative) |given| given.words orelse &.{} else &.{};
        const words = try out.arena.alloc(items_.HeardWord, given_words.len);
        for (given_words, words) |word, *heard| heard.* = .{ .text = word.punctuated_word orelse word.word, .start = word.start, .end = word.end, .speaker = word.speaker };
        try items.settle(out, text);
        try items.segments(out, words);
        const speech_final = result.speech_final == true;
        const ends_item = result.from_finalize == true or (self.connected.ends_at_speech and speech_final and !items.isEmpty());
        if (!ends_item) return;
        if (speech_final) try items.speechStopped(out, result.start + result.duration);
        try items.end(out, null);
    }

    fn write(context: *anyopaque, out: *Out, event: realtime.ClientEvent) WireError!void {
        const self = of(context);
        switch (event) {
            .session_update => |update| {
                if (!std.mem.eql(u8, update.session.model(), self.connected.reference)) {
                    return out.give(try session_.errorEvent(out.arena, &self.ids, .invalid_request, "A session.update names the session's own model", .{}));
                }
                var refusal: Refusal = .{};
                const asked = liveQuery(out.arena, &refusal, self.connected.model_id, &update.session) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Refused => null,
                };
                try items_.answerFixedUpdate(out, &self.ids, "Deepgram", &update.session, asked, refusal, self.connected.query);
            },
            .append => |append| {
                const audio = try items_.audioOf(out.scratch, append.audio) orelse {
                    return out.give(try session_.errorEvent(out.arena, &self.ids, .invalid_request, "The audio appended is not base64", .{}));
                };
                self.items.sent(audio.len);
                try out.send(.{ .binary = audio });
            },
            .commit => {
                if (self.items.isEmpty()) return out.give(try session_.errorEvent(out.arena, &self.ids, .invalid_request, "The buffer holds no audio to commit", .{}));
                try out.send(.{ .text = finalize });
            },
            .clear => try self.items.clear(out),
        }
    }

    fn close(_: *anyopaque, out: *Out) WireError!void {
        try out.send(.{ .text = close_stream });
    }

    /// Deepgram closes the stream once it has answered `CloseStream`.
    fn settled(_: *anyopaque) bool {
        return false;
    }

    fn ended(context: *anyopaque, out: *Out) WireError!void {
        const self = of(context);
        if (!self.items.isEmpty()) try self.items.end(out, null);
    }

    fn deinit(context: *anyopaque) void {
        const self = of(context);
        self.items.deinit();
        self.strings.deinit();
        self.gpa.destroy(self);
    }
};

/// A result: the text of a stretch of the stream, from `start` for `duration` seconds, final or not.
const Results = struct {
    start: f64,
    duration: f64,
    is_final: ?bool = null,
    speech_final: ?bool = null,
    from_finalize: ?bool = null,
    channel: struct {
        alternatives: []const struct {
            transcript: []const u8,
            words: ?[]const struct { word: []const u8, punctuated_word: ?[]const u8 = null, start: f64, end: f64, speaker: ?i64 = null } = null,
        },
    },
};
