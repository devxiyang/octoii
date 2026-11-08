//! The speech kind as `Models` serves it: a request checked against its model — its voices among the model's own, its
//! instructions for a model that takes them — its stored samples read, sent to its provider's stream, its end priced
//! by the characters spoken and the usage reported; and, to create, the audio joined into one.
const std = @import("std");
const Allocator = std.mem.Allocator;
const vocabulary = @import("vocabulary");
const speech = vocabulary.speech;
const SpeechRequest = speech.SpeechRequest;
const driver = @import("../driver.zig");
const Call = driver.Call;
const Error = @import("../failure.zig").Error;
const Model = @import("../catalogue/model.zig").Model;
const Models = @import("../Models.zig");
const stream_ = @import("stream.zig");
const references = @import("references.zig");
const usage = @import("usage.zig");

/// A request of the speech kind, as its stream sends it.
pub const Speech = struct {
    pub const Event = speech.SpeechStreamEvent;
    pub const last = std.meta.Tag(Event).done;

    models: *Models,
    request: SpeechRequest,
    model: ?*const Model = null,
    sent_at_ms: i64 = 0,

    pub fn begin(kind: *Speech, call: *Call) Error!driver.SpeechSource {
        const served = try kind.models.served(call, kind.request.model, .speech);
        call.provider = served.provider;
        const speak = served.provider.driver.speech orelse return call.failWith(.invalid_request, "The provider {s} speaks no text", .{served.provider.id});
        const model = try call.arena.create(Model);
        model.* = served.model;
        kind.model = model;
        kind.sent_at_ms = call.nowMs();
        try checkRequest(call, model, &kind.request);
        const prepared = try call.arena.create(SpeechRequest);
        prepared.* = try withReferencesRead(call, kind.request);
        return speak(call, model, prepared);
    }

    /// The end of the audio with Octoii's account: the meters its provider gave, else the characters spoken and its
    /// usage's, priced.
    pub fn finish(kind: *Speech, _: Allocator, event: Event) Allocator.Error!Event {
        if (event != .done) return event;
        var done = event.done;
        const given = if (done.octoii) |extension| extension.usage else null;
        const meters = given orelse usage.speechMeters(kind.model.?, &kind.request, done.usage);
        done.octoii = .{ .usage = usage.priced(kind.model.?, meters, null, kind.sent_at_ms) };
        return .{ .done = done };
    }
};

pub const SpeechStream = stream_.Stream(Speech);

/// Checks `request`'s voices against the model's own and its instructions against a model that takes them.
fn checkRequest(call: *Call, model: *const Model, request: *const SpeechRequest) Error!void {
    const turns: []const speech.SpeechTurn = switch (request.input) {
        .text => &.{},
        .parts => |given| given,
    };
    try checkVoice(call, model, request.voice);
    var instructed = request.instructions != null;
    for (turns) |turn| {
        try checkVoice(call, model, turn.voice);
        instructed = instructed or turn.instructions != null;
    }
    if (instructed and model.octoii.instructions != true) {
        return call.failWith(.invalid_request, "The model {s} takes no instructions on how to speak: its octoii.instructions is not true", .{try model.reference(call.arena)});
    }
}

/// Checks that a voice of the model's own is one of its `supported_voices`; a voice made for the account is its
/// provider's to know.
fn checkVoice(call: *Call, model: *const Model, voice: ?speech.SpeechVoice) Error!void {
    const given = voice orelse return;
    if (given != .name) return;
    const voices = model.supported_voices orelse return;
    for (voices) |each| if (std.mem.eql(u8, each, given.name)) return;
    return call.failWith(.invalid_request, "The model {s} has no voice \"{s}\": its supported_voices list {s}", .{ try model.reference(call.arena), given.name, try std.mem.join(call.arena, ", ", voices) });
}

/// `request` with its stored samples read into base64 and its images into data URLs.
fn withReferencesRead(call: *Call, request: SpeechRequest) Error!SpeechRequest {
    const given = request.input_references orelse return request;
    const read = try call.arena.alloc(speech.SpeechInputReference, given.len);
    for (given, read, 0..) |reference, *made, index| {
        const what = try std.fmt.allocPrint(call.arena, "The input_references[{d}]", .{index});
        made.* = switch (reference) {
            .text => reference,
            .image => |image| image: {
                const file = try references.read(call, .image, .{ .url = image.image_url.url, .octoii = image.octoii }, false, what);
                break :image .{ .image = .{ .image_url = .{ .url = file.url }, .octoii = file.octoii } };
            },
            .audio => |audio| audio: {
                const stored = if (audio.octoii) |extension| extension.ref != null else false;
                if (!stored) break :audio reference;
                const sample = try references.readAudio(call, .{ .octoii = audio.octoii }, false, what);
                var octoii = sample.octoii;
                octoii.media_type = sample.media_type;
                break :audio .{ .audio = .{ .input_audio = .{ .data = sample.data, .format = audio.input_audio.format orelse references.audioFormat(sample.media_type) }, .octoii = octoii } };
            },
        };
    }
    var prepared = request;
    prepared.input_references = read;
    return prepared;
}

/// Drives `stream` to its end: its audio joined into one, of the media type its deltas name, and the account of its
/// end; or the failure it ended with.
pub fn gathered(arena: Allocator, stream: *SpeechStream) Allocator.Error!stream_.Outcome(speech.SpeechResponse) {
    defer stream.close();
    const decoder = std.base64.standard.Decoder;
    var bytes: std.ArrayList(u8) = .empty;
    var media_type: ?[]const u8 = null;
    var done: ?speech.SpeechAudioDoneEvent = null;
    while (try stream.next()) |event| switch (event) {
        .@"error" => return .{ .failed = stream.failure.? },
        .delta => |delta| {
            if (media_type == null) media_type = delta.octoii.media_type;
            const size = decoder.calcSizeForSlice(delta.audio) catch return stream_.failedWith(speech.SpeechResponse, arena, .invalid_response, "The provider sent audio that is not base64", .{});
            const at = bytes.items.len;
            try bytes.resize(arena, at + size);
            decoder.decode(bytes.items[at..], delta.audio) catch return stream_.failedWith(speech.SpeechResponse, arena, .invalid_response, "The provider sent audio that is not base64", .{});
        },
        .done => |given| done = given,
    };
    if (stream.failure) |failure| return .{ .failed = failure };
    const ended = done orelse return stream_.failedWith(speech.SpeechResponse, arena, .invalid_response, "The stream ended without audio", .{});
    const kind = media_type orelse return stream_.failedWith(speech.SpeechResponse, arena, .invalid_response, "The stream ended without audio", .{});
    const encoder = std.base64.standard.Encoder;
    const data = try arena.alloc(u8, encoder.calcSize(bytes.items.len));
    return .{ .made = .{ .media_type = kind, .data = encoder.encode(data, bytes.items), .usage = if (ended.octoii) |extension| extension.usage else null } };
}
