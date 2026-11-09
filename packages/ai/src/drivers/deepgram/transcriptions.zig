//! Deepgram's transcription kind: its pre-recorded speech-to-text API at `/listen`, every setting in the query, the
//! recording's bytes as the body or its address as JSON for Deepgram to fetch. It answers whole, so the stream is the
//! whole text, each utterance as a segment where speakers are asked for, then the transcript with its seconds.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const oauth = foundation.oauth;
const vocabulary = @import("vocabulary");
const transcriptions = vocabulary.transcriptions;
const Event = transcriptions.TranscriptionStreamEvent;
const seam = @import("../../driver.zig");
const Call = seam.Call;
const Error = @import("../../failure.zig").Error;
const Model = @import("../../catalogue/model.zig").Model;
const http = @import("../../wire/http.zig");
const json = @import("../../wire/json.zig");
const references = @import("../../media/references.zig");
const source = @import("../../wire/source.zig");
const deepgram = @import("../deepgram.zig");

/// The query a transcription request goes to Deepgram with: the model by its id, smart formatting, the language or its
/// detection, the keyterms, diarization, utterances for a verbose transcript, the opt-out of Deepgram's use of the
/// data, and Deepgram's own options; `invalid_request` for what Deepgram does not take.
pub fn query(call: *Call, model: *const Model, request: *const transcriptions.TranscriptionRequest) Error![]const oauth.Field {
    const arena = call.arena;
    const reference = try model.reference(arena);
    if (request.temperature != null) return call.failWith(.invalid_request, "The model {s} cannot take temperature: Deepgram does not offer it", .{reference});
    const policy = request.provider orelse vocabulary.media.DataPolicy{};
    if (policy.zdr != null) return call.failWith(.invalid_request, "The model {s} cannot take zdr: Deepgram does not offer it", .{reference});
    var fields: std.ArrayList(oauth.Field) = .empty;
    try fields.appendSlice(arena, &.{ .{ "model", model.id }, .{ "smart_format", "true" } });
    try fields.append(arena, if (request.language) |language| .{ "language", language } else .{ "detect_language", "true" });
    for (request.keyterms orelse &.{}) |term| try fields.append(arena, .{ "keyterm", term });
    if (request.diarize == true) try fields.append(arena, .{ "diarize_model", "latest" });
    if (request.response_format == .verbose_json) try fields.append(arena, .{ "utterances", "true" });
    if (policy.data_collection == .deny) try fields.append(arena, .{ "mip_opt_out", "true" });
    if (try @import("../../wire/query.zig").appendOptions(arena, &fields, try json.optionsOf(arena, policy.options, "deepgram"))) |name| {
        return call.failWith(.invalid_request, "Deepgram's option {s} is a parameter of its query, which takes text, numbers and booleans", .{name});
    }
    return fields.items;
}

pub fn transcribe(call: *Call, model: *const Model, request: *const transcriptions.TranscriptionRequest) Error!seam.TranscriptionSource {
    const fields = try query(call, model, request);
    const key = try call.apiKey();
    const recording = try recordingBody(call, request.input_audio);
    const response = try http.send(call, .{
        .method = .POST,
        .url = try call.arena.print("{s}/listen?{s}", .{ call.baseUrl(deepgram.base_url), try oauth.formEncoded(call.arena, fields) }),
        .headers = &.{
            .{ .name = "authorization", .value = try call.arena.print("Token {s}", .{key}) },
            .{ .name = "accept", .value = "application/json" },
            .{ .name = "content-type", .value = recording.content_type },
        },
        .body = recording.bytes,
    });
    if (response.status < 200 or response.status >= 300) return call.fail(try http.failureOf(call, response, deepgram.details));
    const answer = try @import("../openrouter/media.zig").jsonBody(Listen, call, response, "transcription");
    return source.listed(Event, call, try eventsOf(call.arena, answer, request));
}

/// The recording as the body: its bytes, of the type its format names, or its address as JSON for Deepgram to fetch.
fn recordingBody(call: *Call, audio: transcriptions.TranscriptionAudio) Error!struct { bytes: []const u8, content_type: []const u8 } {
    switch (audio) {
        .addressed => |given| return .{ .bytes = try foundation.json.encode(call.arena, .{ .url = given.url }), .content_type = "application/json" },
        .stored => return call.failWith(.invalid_request, "The input_audio holds no recording: give its data, its url, or a stored file", .{}),
        .inline_data => |given| {
            const decoder = std.base64.standard.Decoder;
            const size = decoder.calcSizeForSlice(given.data) catch return call.failWith(.invalid_request, "The input_audio's data is not base64", .{});
            const bytes = try call.arena.alloc(u8, size);
            decoder.decode(bytes, given.data) catch return call.failWith(.invalid_request, "The input_audio's data is not base64", .{});
            const media_type = (if (given.octoii) |extension| extension.media_type else null) orelse try references.audioMediaType(call.arena, given.format);
            return .{ .bytes = bytes, .content_type = media_type };
        },
    }
}

/// A stretch of speech by one speaker.
const Utterance = struct { id: ?[]const u8 = null, start: f64, end: f64, transcript: []const u8, speaker: ?u32 = null, channel: ?u32 = null };

/// Deepgram's answer, as far as ai reads it: the recording's length, and the first channel's transcript.
const Listen = struct {
    metadata: struct { duration: f64 },
    results: struct {
        channels: []const struct {
            alternatives: ?[]const struct {
                transcript: []const u8,
                confidence: ?f64 = null,
                words: ?[]const struct { word: []const u8, punctuated_word: ?[]const u8 = null, start: f64, end: f64, confidence: ?f64 = null, speaker: ?u32 = null } = null,
            } = null,
            detected_language: ?[]const u8 = null,
            language_confidence: ?f64 = null,
        },
        utterances: ?[]const Utterance = null,
    },
};

/// The transcript of `answer`: its whole text, each utterance where speakers are asked for, then the transcript.
fn eventsOf(arena: Allocator, answer: Listen, request: *const transcriptions.TranscriptionRequest) Allocator.Error![]const Event {
    const channel = if (answer.results.channels.len > 0) answer.results.channels[0] else null;
    const alternative = if (channel) |given| (if (given.alternatives) |list| (if (list.len > 0) list[0] else null) else null) else null;
    const text = if (alternative) |given| given.transcript else "";
    const utterances = answer.results.utterances orelse &.{};
    var events: std.ArrayList(Event) = .empty;
    try events.append(arena, .{ .delta = .{ .delta = text } });
    if (request.diarize == true) for (utterances, 0..) |utterance, index| try events.append(arena, .{ .segment = .{
        .id = utterance.id orelse try arena.print("{d}", .{index}),
        .start = utterance.start,
        .end = utterance.end,
        .text = utterance.transcript,
        .speaker = try arena.print("{d}", .{utterance.speaker orelse 0}),
    } });
    var done: transcriptions.TranscriptTextDoneEvent = .{ .text = text, .usage = .{ .seconds = answer.metadata.duration } };
    if (request.response_format == .verbose_json) {
        const segments = try arena.alloc(transcriptions.TranscriptionSegment, utterances.len);
        for (utterances, segments, 0..) |utterance, *each, index| each.* = .{ .id = @floatFromInt(index), .start = utterance.start, .end = utterance.end, .text = utterance.transcript, .speaker = if (utterance.speaker) |speaker| @floatFromInt(speaker) else null };
        const given_words = if (alternative) |given| given.words orelse &.{} else &.{};
        const words = try arena.alloc(transcriptions.TranscriptionWord, given_words.len);
        for (given_words, words) |word, *each| each.* = .{ .word = word.punctuated_word orelse word.word, .start = word.start, .end = word.end, .confidence = word.confidence, .speaker = if (word.speaker) |speaker| @floatFromInt(speaker) else null };
        done.octoii = .{ .transcription = .{
            .task = "transcribe",
            .language = (if (channel) |given| given.detected_language else null) orelse request.language,
            .language_confidence = if (channel) |given| given.language_confidence else null,
            .duration = answer.metadata.duration,
            .confidence = if (alternative) |given| given.confidence else null,
            .segments = segments,
            .words = words,
        } };
    }
    try events.append(arena, .{ .done = done });
    return events.items;
}
