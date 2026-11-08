//! xAI's speech kind: its speech API at `/tts`, which names no model and answers with the audio's bytes, streamed as
//! they arrive, of the type its `Content-Type` names. It takes a language with every request, `auto` unless its
//! options give one, and one voice for the whole text.
const std = @import("std");
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const speech = vocabulary.speech;
const seam = @import("../../driver.zig");
const Call = seam.Call;
const Error = @import("../../failure.zig").Error;
const Model = @import("../../catalogue/model.zig").Model;
const source = @import("../../wire/source.zig");
const media = @import("media.zig");

/// The most characters xAI speaks a request.
const text_chars_max = 60_000;

/// The speeds xAI speaks at.
const speed_min = 0.7;
const speed_max = 1.5;

/// The rate of the PCM ai asks xAI for.
const pcm_rate_hz = 24_000;

/// The body of a request to xAI's speech API.
const Body = struct {
    text: []const u8,
    voice_id: ?[]const u8 = null,
    /// Detected from the text unless its options give one.
    language: []const u8 = "auto",
    output_format: ?struct { codec: enum { pcm, mp3 }, sample_rate: ?u32 = null } = null,
    speed: ?f64 = null,
};

/// The speech request as it goes to xAI: its text, its voice as `voice_id`, its language, its format as the codec of
/// its `output_format`, PCM at the rate ai asks for, its speed, and its options among its fields; no model, as the API
/// names none. `invalid_request` for turns, samples, text past its limit, a speed outside its range, timestamps,
/// whose answer is JSON rather than audio, and a `provider` field but its options.
pub fn wireRequest(call: *Call, request: speech.SpeechRequest) Error![]const u8 {
    const own = try media.options(call, request.provider, "speech API");
    const text = switch (request.input) {
        .text => |given| given,
        .parts => return call.failWith(.invalid_request, "xAI speaks text in one voice: give the input as text rather than turns", .{}),
    };
    if (request.input_references) |given| if (given.len > 0) {
        return call.failWith(.invalid_request, "xAI's speech takes no samples: clone a voice through its custom voices, and name it as the voice", .{});
    };
    const characters = std.unicode.utf8CountCodepoints(text) catch text.len;
    if (characters > text_chars_max) return call.failWith(.invalid_request, "xAI speaks at most {d} characters a request, and the input has {d}", .{ text_chars_max, characters });
    if (request.speed) |speed| if (speed < speed_min or speed > speed_max) {
        return call.failWith(.invalid_request, "xAI speaks at a speed of {d} to {d}, and the speed is {d}", .{ speed_min, speed_max, speed });
    };
    if (own) |options| if (options.contains("with_timestamps")) {
        return call.failWith(.invalid_request, "xAI answers with_timestamps with JSON rather than audio, which ai's speech does not carry: leave it out", .{});
    };
    const body: Body = .{
        .text = text,
        .voice_id = if (request.voice) |voice| switch (voice) {
            .name => |name| name,
            .made => |made| made.id,
        } else null,
        .output_format = if (request.response_format) |format| switch (format) {
            .pcm => .{ .codec = .pcm, .sample_rate = pcm_rate_hz },
            .mp3 => .{ .codec = .mp3 },
        } else null,
        .speed = request.speed,
    };
    return foundation.json.encode(call.arena, foundation.json.merged(.{ body, own }));
}

pub fn speak(call: *Call, _: *const Model, request: *const speech.SpeechRequest) Error!seam.SpeechSource {
    const response = try media.send(call, .{ .path = "/tts", .body = try wireRequest(call, request.*), .accept = "audio/*" });
    const asked = if (request.response_format == .pcm) "audio/pcm" else "audio/mpeg";
    return source.audio(call, response, try source.audioMediaType(call.arena, response.header("content-type"), asked, pcm_rate_hz));
}
