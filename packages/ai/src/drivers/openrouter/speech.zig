//! OpenRouter's speech kind: its speech API at `/audio/speech`, which answers with the audio's bytes, streamed as they
//! arrive, of the type its `Content-Type` names. It takes no routing but its data policy.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const speech = vocabulary.speech;
const seam = @import("../../driver.zig");
const Call = seam.Call;
const Error = @import("../../failure.zig").Error;
const Model = @import("../../catalogue/model.zig").Model;
const source = @import("../../wire/source.zig");
const media = @import("media.zig");

/// The speech request as it goes to OpenRouter for `model`: the model by its id, a sample whose type ai read as a data
/// URI of it, and no extensions; `invalid_request` for a voice made for the account, which OpenRouter has none of.
pub fn wireRequest(call: *Call, model: *const Model, request: speech.SpeechRequest) Error![]const u8 {
    var made_voice = if (request.voice) |voice| voice == .made else false;
    switch (request.input) {
        .text => {},
        .parts => |turns| for (turns) |turn| {
            if (turn.voice) |voice| made_voice = made_voice or voice == .made;
        },
    }
    if (made_voice) return call.failWith(.invalid_request, "OpenRouter has no voices made for the account: a voice there is one of the model's supported_voices", .{});
    var sent = request;
    sent.model = model.id;
    if (request.input_references) |given| {
        const plain = try call.arena.alloc(speech.SpeechInputReference, given.len);
        for (given, plain) |reference, *each| each.* = try plainReference(call.arena, reference);
        sent.input_references = plain;
    }
    return foundation.json.encode(call.arena, sent);
}

/// A sample without its extension, as a data URI of the type ai read where its data is base64 alone.
fn plainReference(arena: Allocator, reference: speech.SpeechInputReference) Allocator.Error!speech.SpeechInputReference {
    switch (reference) {
        .text => return reference,
        .image => |image| return .{ .image = .{ .image_url = image.image_url } },
        .audio => |audio| {
            var input = audio.input_audio;
            const media_type = if (audio.octoii) |extension| extension.media_type else null;
            if (media_type != null and input.data != null and !std.mem.startsWith(u8, input.data.?, "data:")) {
                input.data = try std.fmt.allocPrint(arena, "data:{s};base64,{s}", .{ media_type.?, input.data.? });
            }
            return .{ .audio = .{ .input_audio = input } };
        },
    }
}

pub fn speak(call: *Call, model: *const Model, request: *const speech.SpeechRequest) Error!seam.SpeechSource {
    const response = try media.send(call, "/audio/speech", try wireRequest(call, model, request.*), "audio/*");
    const asked = if (request.response_format == .mp3) "audio/mpeg" else "audio/pcm";
    return source.audio(call, response, try source.audioMediaType(call.arena, response.header("content-type"), asked, 24_000));
}
