//! xAI's realtime transcription: its streaming speech-to-text at the WebSocket `/stt`, every setting in the query and the
//! audio as binary frames, open once `transcript.created` has come. Its results become the items its stream has none
//! of: a result not final is the item's partial text, a final one its delta, and an utterance final, which repeats the
//! utterance's settled text, adds what follows it and ends the item. A commit is `finalize`, and `close()` is
//! `audio.done`, after which xAI sends `transcript.done` and closes.
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
const xai = @import("../xai.zig");

/// The messages xAI's stream takes besides audio.
const finalize = "{\"type\":\"finalize\"}";
const audio_done = "{\"type\":\"audio.done\"}";

pub const calls: seam.RealtimeCalls = .{ .connect = connect };

/// The query a session goes to xAI's stream with: the model by its id, the audio's format, interim results, its one
/// language, its keyterms, the silence that ends speech, and xAI's own options; `Refused` for a setting xAI does not
/// take, several languages among them, as it takes one and detects the rest.
pub fn sttQuery(arena: Allocator, refusal: *Refusal, model_id: []const u8, session: *const realtime.Session) Refusal.Error![]const u8 {
    try items_.checkStreamSettings(arena, refusal, "xAI", session);
    const input = &session.audio.input;
    const languages = session.languages();
    if (languages.len > 1) return refusal.refuse(arena, "xAI's realtime transcription takes one language, and detects the others itself", .{});
    var fields: std.ArrayList(oauth.Field) = .empty;
    try fields.appendSlice(arena, &.{ .{ "model", model_id }, .{ "encoding", "pcm" }, .{ "sample_rate", "24000" }, .{ "interim_results", "true" } });
    for (languages) |language| try fields.append(arena, .{ "language", language });
    for (input.transcription.keywords orelse &.{}) |keyword| try fields.append(arena, .{ "keyterm", keyword });
    const turn = if (input.turn_detection) |given| given.given() else null;
    if (turn) |detection| if (detection.silence_duration_ms) |silence| try fields.append(arena, .{ "endpointing", try arena.print("{d}", .{silence}) });
    const options = if (session.provider) |provider| try json.optionsOf(arena, provider.options, "xai") else null;
    if (try query_.appendOptions(arena, &fields, options)) |name| {
        return refusal.refuse(arena, "xAI's option {s} is a parameter of its query, which takes text, numbers and booleans", .{name});
    }
    return oauth.formEncoded(arena, fields.items);
}

fn connect(call: *Call, model: *const Model, session: *const realtime.Session, gpa: Allocator) Error!seam.RealtimeOpening {
    var refusal: Refusal = .{};
    const query = sttQuery(call.arena, &refusal, model.id, session) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Refused => return call.failWith(.invalid_request, "{s}", .{refusal.message.?}),
    };
    const key = try call.apiKey();
    const turn = session.audio.input.turn_detection;
    const wire = try Wire.create(gpa, .{
        .reference = try model.reference(call.arena),
        .model_id = model.id,
        .state = (try items_.sessionState(call.arena, session)).text,
        .query = query,
        .ends_at_speech = !(turn != null and turn.? == .null),
    });
    return .{
        .url = try session_.socketUrl(call.arena, call.baseUrl(xai.base_url), "/stt", query),
        .headers = try call.arena.dupe(foundation.http.Header, &.{.{ .name = "authorization", .value = try call.arena.print("Bearer {s}", .{key}) }}),
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

/// How a session speaks over xAI's stream.
const Wire = struct {
    gpa: Allocator,
    strings_arena: std.heap.ArenaAllocator,
    connected: Connected,
    ids: session_.Ids = .{},
    items: items_.HeardItems,
    /// Whether a commit asked for the item under way to end at the next utterance's end.
    committed: bool = false,

    fn create(gpa: Allocator, connected: Connected) Allocator.Error!*Wire {
        const made = try gpa.create(Wire);
        errdefer gpa.destroy(made);
        made.* = .{ .gpa = gpa, .strings_arena = .init(gpa), .connected = undefined, .items = undefined };
        errdefer made.strings_arena.deinit();
        const arena = made.strings_arena.allocator();
        made.connected = .{
            .reference = try arena.dupe(u8, connected.reference),
            .model_id = try arena.dupe(u8, connected.model_id),
            .state = try arena.dupe(u8, connected.state),
            .query = try arena.dupe(u8, connected.query),
            .ends_at_speech = connected.ends_at_speech,
        };
        made.items = .init(gpa, &made.ids);
        return made;
    }

    fn wire(self: *Wire) session_.Wire {
        return .{
            .context = self,
            .vtable = &.{ .start = start, .read = read, .write = write, .close = close, .settled = settled, .ended = ended, .deinit = deinit },
            .opens_on = .session_created,
        };
    }

    fn of(context: *anyopaque) *Wire {
        return @ptrCast(@alignCast(context));
    }

    /// The session opens on xAI's own ready signal.
    fn start(_: *anyopaque, _: *Out) WireError!void {}

    fn read(context: *anyopaque, out: *Out, message: foundation.websocket.Message) WireError!void {
        const self = of(context);
        const text = switch (message) {
            .text => |given| given,
            .binary => return out.brokenBy("xAI sent a message that is no JSON event", .{}),
        };
        const value = std.json.parseFromSliceLeaky(std.json.Value, out.arena, text, .{ .allocate = .alloc_always }) catch return out.brokenBy("xAI sent a message that is no JSON event", .{});
        const kind = json.textOf(value, "type") orelse return out.brokenBy("xAI sent a message that is no JSON event", .{});
        if (std.mem.eql(u8, kind, "transcript.created")) {
            return out.give(.{ .session_created = .{ .session = .{ .text = self.connected.state }, .event_id = try self.ids.event(out.arena) } });
        }
        if (std.mem.eql(u8, kind, "transcript.partial")) {
            const result = foundation.json.decodeValue(Partial, out.arena, value) catch return;
            const ends_item = result.speech_final and (self.connected.ends_at_speech or self.committed);
            if (ends_item) self.committed = false;
            return self.resultEvents(out, result, ends_item);
        }
        if (std.mem.eql(u8, kind, "transcript.done")) {
            if (!self.items.isEmpty()) try self.items.end(out, null);
            return;
        }
        if (std.mem.eql(u8, kind, "error")) {
            const said = foundation.json.decodeValue(struct { message: []const u8 }, out.arena, value) catch return;
            return out.give(.{ .@"error" = .{ .@"error" = session_.realtimeError(.server, said.message, null), .event_id = try self.ids.event(out.arena) } });
        }
    }

    /// The events of a result: an interim one's partial text, a final one's settled text after what the item settled,
    /// as an utterance final repeats it, with its speakers; and, where it ends the item, speech heard to stop and the
    /// item's end.
    fn resultEvents(self: *Wire, out: *Out, result: Partial, ends_item: bool) Allocator.Error!void {
        const items = &self.items;
        if (items.isCleared(result.start, result.duration)) return;
        const settled_text = items.settledText();
        const repeats = settled_text.len > 0 and std.mem.startsWith(u8, result.text, settled_text);
        const text = if (repeats) std.mem.trim(u8, result.text[settled_text.len..], " \t\r\n") else result.text;
        if (!result.is_final) return if (text.len > 0) items.heard(out, text);
        const given_words = result.words orelse &.{};
        const words = try out.arena.alloc(items_.HeardWord, given_words.len);
        for (given_words, words) |word, *heard| heard.* = .{ .text = word.text orelse word.word orelse "", .start = word.start, .end = word.end, .speaker = word.speaker };
        try items.settle(out, text);
        // The words of a result that repeats the settled text were given as segments with it.
        if (!repeats) try items.segments(out, words);
        if (!ends_item) return;
        try items.speechStopped(out, result.start + result.duration);
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
                const asked = sttQuery(out.arena, &refusal, self.connected.model_id, &update.session) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Refused => null,
                };
                try items_.answerFixedUpdate(out, &self.ids, "xAI", &update.session, asked, refusal, self.connected.query);
            },
            .append => |append| {
                const audio = try items_.audioOf(out.scratch_arena, append.audio) orelse {
                    return out.give(try session_.errorEvent(out.arena, &self.ids, .invalid_request, "The audio appended is not base64", .{}));
                };
                self.items.sent(audio.len);
                try out.send(.{ .binary = audio });
            },
            .commit => {
                if (self.items.isEmpty()) return out.give(try session_.errorEvent(out.arena, &self.ids, .invalid_request, "The buffer holds no audio to commit", .{}));
                self.committed = true;
                try out.send(.{ .text = finalize });
            },
            .clear => try self.items.clear(out),
        }
    }

    fn close(_: *anyopaque, out: *Out) WireError!void {
        try out.send(.{ .text = audio_done });
    }

    /// xAI closes the stream once it has sent `transcript.done`.
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
        self.strings_arena.deinit();
        self.gpa.destroy(self);
    }
};

/// A result: the text of a stretch of the stream, from `start` for `duration` seconds, interim, chunk final or
/// utterance final.
const Partial = struct {
    text: []const u8,
    words: ?[]const struct { text: ?[]const u8 = null, word: ?[]const u8 = null, start: f64, end: f64, speaker: ?i64 = null } = null,
    is_final: bool,
    speech_final: bool,
    start: f64,
    duration: f64,
};
