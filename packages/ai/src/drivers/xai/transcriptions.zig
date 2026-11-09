//! xAI's transcription kind: its speech-to-text API at `/stt`, which takes a multipart form, the recording last as its
//! file or its address, and answers with JSON, given as the whole text and then the transcript: with `verbose_json`,
//! its language, duration and words. It reports no usage, so the account is the seconds of the recording.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const multipart = foundation.multipart;
const vocabulary = @import("vocabulary");
const transcriptions = vocabulary.transcriptions;
const Event = transcriptions.TranscriptionStreamEvent;
const seam = @import("../../driver.zig");
const Call = seam.Call;
const Error = @import("../../failure.zig").Error;
const Model = @import("../../catalogue/model.zig").Model;
const source = @import("../../wire/source.zig");
const media = @import("media.zig");

/// The formats of raw recordings, which name no rate of their own, so xAI is told theirs.
const raw_formats = [_][]const u8{ "pcm", "mulaw", "alaw" };

/// The transcription request as xAI's form for `model`: the model by its id, a raw recording's format and rate, its
/// language, its speakers asked for, its key terms, its options as fields, and the recording last, as its file or its
/// address; `invalid_request` for a temperature, segment timestamps, a raw recording without its rate, an option that
/// is no text, number or flag, and a `provider` field but its options.
pub fn form(call: *Call, model: *const Model, request: *const transcriptions.TranscriptionRequest) Error![]const multipart.Field {
    const arena = call.arena;
    const own = try media.options(call, request.provider, "transcription API");
    if (request.temperature != null) return call.failWith(.invalid_request, "xAI's transcription takes no temperature", .{});
    for (request.timestamp_granularities orelse &.{}) |granularity| if (granularity == .segment) {
        return call.failWith(.invalid_request, "xAI's transcription writes words and no segments: ask for word timestamps alone", .{});
    };
    const format: ?[]const u8 = switch (request.input_audio) {
        .inline_data => |given| given.format,
        .addressed => |given| given.format,
        .stored => |given| given.format,
    };
    const raw = if (format) |given| for (raw_formats) |each| {
        if (std.mem.eql(u8, each, given)) break true;
    } else false else false;
    const rated = if (own) |options| options.contains("sample_rate") else false;
    if (raw and !rated) return call.failWith(.invalid_request, "xAI reads a {s} recording at the rate it is told: give its sample_rate in the provider options", .{format.?});
    var fields: std.ArrayList(multipart.Field) = .empty;
    try fields.append(arena, .{ .name = "model", .value = model.id });
    if (raw) try fields.append(arena, .{ .name = "audio_format", .value = format.? });
    if (request.language) |language| try fields.append(arena, .{ .name = "language", .value = language });
    if (request.diarize) |diarize| try fields.append(arena, .{ .name = "diarize", .value = if (diarize) "true" else "false" });
    for (request.keyterms orelse &.{}) |term| try fields.append(arena, .{ .name = "keyterm", .value = term });
    if (own) |options| {
        var it = options.iterator();
        while (it.next()) |entry| {
            const values: []const std.json.Value = if (entry.value_ptr.* == .array) entry.value_ptr.array.items else &.{entry.value_ptr.*};
            for (values) |value| try fields.append(arena, .{ .name = entry.key_ptr.*, .value = try optionText(call, entry.key_ptr.*, value) });
        }
    }
    try fields.append(arena, try recordingField(call, request.input_audio));
    return fields.items;
}

/// An option's value as a form's field: a text, a number or a flag as its text.
fn optionText(call: *Call, name: []const u8, value: std.json.Value) Error![]const u8 {
    return switch (value) {
        .string => |text| text,
        .integer, .float, .number_string, .bool => foundation.json.encode(call.arena, value),
        else => call.failWith(.invalid_request, "xAI's transcription takes its option {s} as a form's field: give it as a text, a number or a flag", .{name}),
    };
}

/// The recording as the form's last field: its bytes as a file named by its format, or its address.
fn recordingField(call: *Call, audio: transcriptions.TranscriptionAudio) Error!multipart.Field {
    switch (audio) {
        .addressed => |given| return .{ .name = "url", .value = given.url },
        .stored => return call.failWith(.invalid_request, "The input_audio holds no recording to send: ai reads a stored one before it reaches xAI", .{}),
        .inline_data => |given| {
            const decoder = std.base64.standard.Decoder;
            const size = decoder.calcSizeForSlice(given.data) catch return call.failWith(.invalid_request, "The input_audio's data is not base64", .{});
            const bytes = try call.arena.alloc(u8, size);
            decoder.decode(bytes, given.data) catch return call.failWith(.invalid_request, "The input_audio's data is not base64", .{});
            const named = std.StaticStringMap([]const u8).initComptime(.{ .{ "mp3", "audio/mpeg" }, .{ "m4a", "audio/mp4" }, .{ "mulaw", "audio/basic" } });
            const media_type = (if (given.octoii) |extension| extension.media_type else null) orelse named.get(given.format) orelse try call.arena.print("audio/{s}", .{given.format});
            return .{ .name = "file", .filename = try call.arena.print("audio.{s}", .{given.format}), .content_type = media_type, .data = bytes };
        },
    }
}

/// What xAI's transcription answers with, of which ai reads these fields.
const Answer = struct {
    text: []const u8,
    language: ?[]const u8 = null,
    duration: ?f64 = null,
    words: ?[]const struct { text: []const u8, start: f64, end: f64, confidence: ?f64 = null, speaker: ?f64 = null } = null,
};

pub fn transcribe(call: *Call, model: *const Model, request: *const transcriptions.TranscriptionRequest) Error!seam.TranscriptionSource {
    const fields = try form(call, model, request);
    const body = try multipart.encode(call.arena, try call.host.boundary(call.arena), fields);
    const response = try media.send(call, .{ .path = "/stt", .body = body.bytes, .content_type = body.content_type, .accept = "application/json" });
    const answer = try media.jsonBody(Answer, call, response, "transcription");
    const verbose = request.response_format == .verbose_json;
    const details: ?transcriptions.TranscriptionDetails = if (verbose and (answer.language != null or answer.duration != null or answer.words != null)) .{
        .language = answer.language,
        .duration = answer.duration,
        .words = if (answer.words) |words| try vocabularyWords(call.arena, words) else null,
    } else null;
    const done: Event = .{ .done = .{
        .text = answer.text,
        .usage = if (answer.duration) |seconds| .{ .seconds = seconds } else null,
        .octoii = if (details) |given| .{ .transcription = given } else null,
    } };
    return source.listed(Event, call, try call.arena.dupe(Event, &.{ .{ .delta = .{ .delta = answer.text } }, done }));
}

/// xAI's words as the vocabulary's, each word's `text` as its `word`.
fn vocabularyWords(arena: Allocator, words: @typeInfo(@FieldType(Answer, "words")).optional.child) Allocator.Error![]const transcriptions.TranscriptionWord {
    const made = try arena.alloc(transcriptions.TranscriptionWord, words.len);
    for (words, made) |word, *each| each.* = .{ .word = word.text, .type = .word, .start = word.start, .end = word.end, .confidence = word.confidence, .speaker = word.speaker };
    return made;
}
