//! OpenAI's speech kind: its speech API at `/audio/speech`, asked for server-sent events, whose `speech.audio.delta`
//! and `speech.audio.done` are the vocabulary's own, each delta naming what its audio is. A voice made for the account
//! goes as its id.
const std = @import("std");
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const speech = vocabulary.speech;
const Event = speech.SpeechStreamEvent;
const seam = @import("../../driver.zig");
const Call = seam.Call;
const failure_ = @import("../../failure.zig");
const Error = failure_.Error;
const Model = @import("../../catalogue/model.zig").Model;
const source = @import("../../wire/source.zig");
const media = @import("media.zig");

/// The body of a request to OpenAI's speech API.
const Body = struct {
    input: []const u8,
    voice: ?speech.SpeechVoice = null,
    instructions: ?[]const u8 = null,
    response_format: @FieldType(speech.SpeechRequest, "response_format") = null,
    speed: ?f64 = null,
};

/// The request as it goes to OpenAI for `model`: the model by its id, a voice made for the account as its id,
/// OpenAI's own options, and its events as a stream; `invalid_request` for turns of several speakers and for samples,
/// which OpenAI's speech takes neither of.
pub fn wireRequest(call: *Call, model: *const Model, request: speech.SpeechRequest) Error![]const u8 {
    const text = switch (request.input) {
        .text => |given| given,
        .parts => return call.failWith(.invalid_request, "OpenAI's speech API speaks one text: it takes no turns of several speakers", .{}),
    };
    if (request.input_references != null) return call.failWith(.invalid_request, "OpenAI's speech API takes no input_references: make a voice for the account instead", .{});
    const own = try media.options(call, request.provider, "speech API");
    const body: Body = .{ .input = text, .voice = request.voice, .instructions = request.instructions, .response_format = request.response_format, .speed = request.speed };
    return foundation.json.encode(call.arena, foundation.json.merged(.{ body, own, .{ .model = model.id, .stream_format = "sse" } }));
}

pub fn speak(call: *Call, model: *const Model, request: *const speech.SpeechRequest) Error!seam.SpeechSource {
    const body = try wireRequest(call, model, request.*);
    const response = try media.send(call, .{ .path = "/audio/speech", .accept = "text/event-stream", .body = body });
    const Translator = struct {
        fn pcm(given: *Call, data: []const u8, out: *std.ArrayList(Event)) Error!void {
            try out.append(given.arena, try eventOf(given, data, "audio/pcm;rate=24000"));
        }
        fn mp3(given: *Call, data: []const u8, out: *std.ArrayList(Event)) Error!void {
            try out.append(given.arena, try eventOf(given, data, "audio/mpeg"));
        }
    };
    return source.of(Event, call, response, if (request.response_format == .pcm) Translator.pcm else Translator.mp3);
}

/// The event of the vocabulary one of OpenAI's speech events stands for, its audio of `media_type`.
fn eventOf(call: *Call, data: []const u8, media_type: []const u8) Error!Event {
    const value = std.json.parseFromSliceLeaky(std.json.Value, call.arena, data, .{ .allocate = .alloc_always }) catch return unknown(call, data);
    const Wire = struct { type: []const u8, audio: ?[]const u8 = null, usage: @FieldType(speech.SpeechAudioDoneEvent, "usage") = null };
    const event = foundation.json.decodeValue(Wire, call.arena, value) catch return unknown(call, data);
    if (std.mem.eql(u8, event.type, "error")) return .{ .@"error" = media.errorEvent(call.arena, value) orelse return unknown(call, data) };
    if (std.mem.eql(u8, event.type, "speech.audio.delta")) return .{ .delta = .{ .audio = event.audio orelse return unknown(call, data), .octoii = .{ .media_type = media_type } } };
    if (std.mem.eql(u8, event.type, "speech.audio.done")) return .{ .done = .{ .usage = event.usage } };
    return unknown(call, data);
}

fn unknown(call: *Call, data: []const u8) Error {
    var failure: failure_.Failure = .init(.invalid_response, "The provider sent a speech event ai does not know");
    failure.body = data;
    return call.fail(failure);
}
