//! OpenAI's transcription kind: its transcription API at `/audio/transcriptions`, which takes the recording as a file
//! of multipart form data, `language` as `languages` and `keyterms` as `keywords`. A model that streams is asked for
//! server-sent events where it answers in JSON, its `transcript.text.*` events the vocabulary's own; else its JSON
//! answer is given as the whole text and then the transcript with the rest of the response. Its usage is in tokens or
//! in seconds, as its `type` says, and the first language it heard is the transcription's.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const multipart = foundation.multipart;
const vocabulary = @import("vocabulary");
const transcriptions = vocabulary.transcriptions;
const Event = transcriptions.TranscriptionStreamEvent;
const seam = @import("../../driver.zig");
const Call = seam.Call;
const failure_ = @import("../../failure.zig");
const Error = failure_.Error;
const Model = @import("../../catalogue/model.zig").Model;
const references = @import("../../media/references.zig");
const source = @import("../../wire/source.zig");
const media = @import("media.zig");

/// Whether a request to `model` streams: the model streams, and the answer is JSON, the one format that does.
fn streams(model: *const Model, request: *const transcriptions.TranscriptionRequest) bool {
    return model.supports_streaming == true and (request.response_format orelse .json) == .json;
}

/// The request as OpenAI's form fields for `model`, the recording beside them: the model by its id, the fields it
/// takes under its names, OpenAI's own options, and a stream where it streams; `invalid_request` for `diarize`.
pub fn formFields(call: *Call, model: *const Model, request: *const transcriptions.TranscriptionRequest) Error![]const multipart.Field {
    const arena = call.arena;
    if (request.diarize == true) return call.failWith(.invalid_request, "OpenAI's transcription API takes no diarize: its models tell no speakers apart in verbose_json", .{});
    const own = try media.options(call, request.provider, "transcription API");
    var fields: std.ArrayList(multipart.Field) = .empty;
    try fields.append(arena, .{ .name = "model", .value = model.id });
    if (request.language) |language| try fields.append(arena, .{ .name = "languages[]", .value = language });
    if (request.temperature) |temperature| try fields.append(arena, .{ .name = "temperature", .value = try std.fmt.allocPrint(arena, "{d}", .{temperature}) });
    if (request.response_format) |format| try fields.append(arena, .{ .name = "response_format", .value = @tagName(format) });
    for (request.timestamp_granularities orelse &.{}) |granularity| try fields.append(arena, .{ .name = "timestamp_granularities[]", .value = @tagName(granularity) });
    for (request.keyterms orelse &.{}) |term| try fields.append(arena, .{ .name = "keywords[]", .value = term });
    if (own) |options| try appendOptions(arena, &fields, options);
    if (streams(model, request)) try fields.append(arena, .{ .name = "stream", .value = "true" });
    return fields.items;
}

/// The form fields of `options`, in order: text as it is, an array as a field of each entry under its name with
/// `[]`, as OpenAI's form fields take lists, and anything else as JSON; a null sends nothing.
pub fn appendOptions(arena: Allocator, fields: *std.ArrayList(multipart.Field), options: std.json.ObjectMap) Allocator.Error!void {
    var it = options.iterator();
    while (it.next()) |entry| switch (entry.value_ptr.*) {
        .null => {},
        .array => |entries| for (entries.items) |each| {
            try fields.append(arena, .{ .name = try std.fmt.allocPrint(arena, "{s}[]", .{entry.key_ptr.*}), .value = try fieldText(arena, each) });
        },
        else => try fields.append(arena, .{ .name = entry.key_ptr.*, .value = try fieldText(arena, entry.value_ptr.*) }),
    };
}

fn fieldText(arena: Allocator, value: std.json.Value) Allocator.Error![]const u8 {
    return if (value == .string) value.string else foundation.json.encode(arena, value);
}

/// A recording as the file OpenAI takes it, named `name`: its bytes, `audio.<format>` and its type; one at an address
/// fetched first, as OpenAI fetches none.
pub fn recordingPart(call: *Call, name: []const u8, audio: transcriptions.TranscriptionAudio) Error!multipart.Field {
    const what = "The input_audio";
    switch (audio) {
        .inline_data => |given| return filePart(call, name, given.data, given.format, if (given.octoii) |extension| extension.media_type else null),
        .addressed => |given| {
            const fetched = try references.readAudio(call, .{ .url = given.url, .octoii = given.octoii }, true, what);
            return filePart(call, name, fetched.data, given.format orelse references.audioFormat(fetched.media_type), fetched.media_type);
        },
        .stored => return call.failWith(.invalid_request, "{s} holds no recording to send", .{what}),
    }
}

fn filePart(call: *Call, name: []const u8, base64: []const u8, format: []const u8, media_type: ?[]const u8) Error!multipart.Field {
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(base64) catch return call.failWith(.invalid_request, "The input_audio's data is not base64", .{});
    const bytes = try call.arena.alloc(u8, size);
    decoder.decode(bytes, base64) catch return call.failWith(.invalid_request, "The input_audio's data is not base64", .{});
    return .{ .name = name, .filename = try std.fmt.allocPrint(call.arena, "audio.{s}", .{format}), .content_type = media_type orelse try references.audioMediaType(call.arena, format), .data = bytes };
}

pub fn transcribe(call: *Call, model: *const Model, request: *const transcriptions.TranscriptionRequest) Error!seam.TranscriptionSource {
    const fields = try formFields(call, model, request);
    const file = try recordingPart(call, "file", request.input_audio);
    var all: std.ArrayList(multipart.Field) = .empty;
    try all.append(call.arena, file);
    try all.appendSlice(call.arena, fields);
    const form = try multipart.encode(call.arena, try call.host.boundary(call.arena), all.items);
    const accept = if (streams(model, request)) "text/event-stream" else "application/json";
    const response = try media.send(call, .{ .path = "/audio/transcriptions", .accept = accept, .body = form.bytes, .content_type = form.content_type });
    if (media.streams(response)) {
        const Translator = struct {
            fn translate(given: *Call, data: []const u8, out: *std.ArrayList(Event)) Error!void {
                try out.append(given.arena, try eventOf(given, data));
            }
        };
        return source.of(Event, call, response, Translator.translate);
    }
    const answer = try media.jsonBody(WireTranscription, call, response, "transcription");
    var details: transcriptions.TranscriptionDetails = .{};
    inline for (comptime std.meta.fieldNames(transcriptions.TranscriptionDetails)) |name| @field(details, name) = @field(answer, name);
    return source.listed(Event, call, try call.arena.dupe(Event, &.{ .{ .delta = .{ .delta = answer.text } }, doneEvent(answer.text, null, answer.usage, details, answer.languages) }));
}

/// What a transcription used, as OpenAI reports it: tokens, or the seconds of the recording.
const WireUsage = struct {
    type: enum { tokens, duration },
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    total_tokens: ?u64 = null,
    seconds: ?f64 = null,

    fn usage(given: WireUsage) transcriptions.TranscriptionUsage {
        return switch (given.type) {
            .duration => .{ .seconds = given.seconds },
            .tokens => .{ .input_tokens = given.input_tokens, .output_tokens = given.output_tokens, .total_tokens = given.total_tokens },
        };
    }
};

const Languages = ?[]const struct { code: []const u8 };

/// OpenAI's answer that does not stream: the text, its details as the vocabulary names them, the languages it heard,
/// and its usage.
const WireTranscription = struct {
    text: []const u8,
    task: ?[]const u8 = null,
    language: ?[]const u8 = null,
    language_confidence: ?f64 = null,
    duration: ?f64 = null,
    confidence: ?f64 = null,
    segments: ?[]const transcriptions.TranscriptionSegment = null,
    words: ?[]const transcriptions.TranscriptionWord = null,
    entities: @FieldType(transcriptions.TranscriptionDetails, "entities") = null,
    languages: Languages = null,
    usage: ?WireUsage = null,
};

/// The event of the vocabulary one event of OpenAI's transcription stream stands for.
fn eventOf(call: *Call, data: []const u8) Error!Event {
    const value = std.json.parseFromSliceLeaky(std.json.Value, call.arena, data, .{ .allocate = .alloc_always }) catch return unknown(call, data);
    const kind = if (value == .object) value.object.get("type") else null;
    const named = if (kind) |given| (if (given == .string) given.string else "") else "";
    if (std.mem.eql(u8, named, "error")) return .{ .@"error" = media.errorEvent(call.arena, value) orelse return unknown(call, data) };
    if (std.mem.eql(u8, named, "transcript.text.done")) {
        const done = foundation.json.decodeValue(struct { text: []const u8, logprobs: ?[]const foundation.json.Raw = null, languages: Languages = null, usage: ?WireUsage = null }, call.arena, value) catch return unknown(call, data);
        return doneEvent(done.text, done.logprobs, done.usage, .{}, done.languages);
    }
    if (std.mem.eql(u8, named, "transcript.text.delta") or std.mem.eql(u8, named, "transcript.text.segment")) {
        return foundation.json.decodeValue(Event, call.arena, value) catch unknown(call, data);
    }
    return unknown(call, data);
}

fn unknown(call: *Call, data: []const u8) Error {
    var failure: failure_.Failure = .init(.invalid_response, "The provider sent a transcription event ai does not know");
    failure.body = data;
    return call.fail(failure);
}

/// A transcript's end: its text, its usage in the vocabulary's shape, and the rest of the response, where there is
/// any, its language the one it gives, else the first it heard.
fn doneEvent(text: []const u8, logprobs: ?[]const foundation.json.Raw, usage: ?WireUsage, given: transcriptions.TranscriptionDetails, languages: Languages) Event {
    var details = given;
    if (details.language == null) if (languages) |heard| if (heard.len > 0) {
        details.language = heard[0].code;
    };
    const empty = inline for (comptime std.meta.fieldNames(transcriptions.TranscriptionDetails)) |name| {
        if (@field(details, name) != null) break false;
    } else true;
    return .{ .done = .{
        .text = text,
        .logprobs = logprobs,
        .usage = if (usage) |reported| reported.usage() else null,
        .octoii = if (empty) null else .{ .transcription = details },
    } };
}
