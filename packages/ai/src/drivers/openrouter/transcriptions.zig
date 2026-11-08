//! OpenRouter's transcription kind: its transcription API at `/audio/transcriptions`, which answers with JSON, given as
//! the whole text and then the transcript with the rest of the response. It takes no routing but its data policy.
const std = @import("std");
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const transcriptions = vocabulary.transcriptions;
const Event = transcriptions.TranscriptionStreamEvent;
const seam = @import("../../driver.zig");
const Call = seam.Call;
const Error = @import("../../failure.zig").Error;
const Model = @import("../../catalogue/model.zig").Model;
const source = @import("../../wire/source.zig");
const media = @import("media.zig");

/// The transcription request as it goes to OpenRouter for `model`: the model by its id, and no extensions.
pub fn wireRequest(arena: std.mem.Allocator, model: *const Model, request: transcriptions.TranscriptionRequest) std.mem.Allocator.Error![]const u8 {
    var sent = request;
    sent.model = model.id;
    sent.input_audio = switch (request.input_audio) {
        .inline_data => |given| .{ .inline_data = .{ .data = given.data, .format = given.format } },
        .addressed => |given| .{ .addressed = .{ .url = given.url, .format = given.format } },
        .stored => request.input_audio,
    };
    return foundation.json.encode(arena, sent);
}

pub fn transcribe(call: *Call, model: *const Model, request: *const transcriptions.TranscriptionRequest) Error!seam.TranscriptionSource {
    const response = try media.send(call, "/audio/transcriptions", try wireRequest(call.arena, model, request.*), "application/json");
    const answer = try media.jsonBody(transcriptions.TranscriptionResponse, call, response, "transcription");
    var details: transcriptions.TranscriptionDetails = .{};
    var empty = true;
    inline for (comptime std.meta.fieldNames(transcriptions.TranscriptionDetails)) |name| {
        @field(details, name) = @field(answer, name);
        if (@field(answer, name) != null) empty = false;
    }
    const done: Event = .{ .done = .{ .text = answer.text, .usage = answer.usage, .octoii = if (empty) null else .{ .transcription = details } } };
    return source.listed(Event, call, try call.arena.dupe(Event, &.{ .{ .delta = .{ .delta = answer.text } }, done }));
}
