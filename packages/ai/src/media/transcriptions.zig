//! The transcription kind as `Models` serves it: a request checked against its model — audio it reads, speakers from a
//! model that tells them apart, a format it answers in, what only `verbose_json` holds asked with it — its stored
//! recording read, sent to its provider's stream, its end priced; and, to create, the response its end carries.
const std = @import("std");
const Allocator = std.mem.Allocator;
const vocabulary = @import("vocabulary");
const transcriptions = vocabulary.transcriptions;
const TranscriptionRequest = transcriptions.TranscriptionRequest;
const driver = @import("../driver.zig");
const Call = driver.Call;
const Error = @import("../failure.zig").Error;
const Model = @import("../catalogue/model.zig").Model;
const Models = @import("../Models.zig");
const stream_ = @import("stream.zig");
const references = @import("references.zig");
const usage = @import("usage.zig");

/// A request of the transcription kind, as its stream sends it.
pub const Transcriptions = struct {
    pub const Event = transcriptions.TranscriptionStreamEvent;
    pub const last = std.meta.Tag(Event).done;

    models: *Models,
    request: TranscriptionRequest,
    model: ?*const Model = null,
    sent_at_ms: i64 = 0,

    pub fn begin(kind: *Transcriptions, call: *Call) Error!driver.TranscriptionSource {
        const served = try kind.models.served(call, kind.request.model, .transcription);
        call.provider = served.provider;
        const transcribe = served.provider.driver.transcription orelse return call.failWith(.invalid_request, "The provider {s} transcribes nothing", .{served.provider.id});
        const model = try call.arena.create(Model);
        model.* = served.model;
        kind.model = model;
        kind.sent_at_ms = call.nowMs();
        try checkRequest(call, model, &kind.request);
        const prepared = try call.arena.create(TranscriptionRequest);
        prepared.* = kind.request;
        prepared.input_audio = try references.readRecording(call, kind.request.input_audio, "The input_audio");
        return transcribe(call, model, prepared);
    }

    /// The end of the transcript with Octoii's account: the meters its provider gave, else its usage's, priced.
    pub fn finish(kind: *Transcriptions, _: Allocator, event: Event) Allocator.Error!Event {
        if (event != .done) return event;
        var done = event.done;
        var octoii = done.octoii orelse @TypeOf(done.octoii.?){};
        const meters = octoii.usage orelse usage.transcriptionMeters(kind.model.?, done.usage);
        octoii.usage = usage.priced(kind.model.?, meters, if (done.usage) |given| given.cost else null, kind.sent_at_ms);
        done.octoii = octoii;
        return .{ .done = done };
    }
};

pub const TranscriptionStream = stream_.Stream(Transcriptions);

/// Checks `request` against `model`: audio it reads, speakers but from a model that does not tell them apart, a
/// format it answers in, and what only `verbose_json` holds asked with it.
fn checkRequest(call: *Call, model: *const Model, request: *const TranscriptionRequest) Error!void {
    const reference = try model.reference(call.arena);
    if (!model.reads(.audio)) return call.failWith(.invalid_request, "The request holds a recording, and the model {s} does not read audio: its architecture.input_modalities lack it", .{reference});
    const diarized = request.diarize == true;
    if (diarized and model.octoii.speakers == false) return call.failWith(.invalid_request, "The model {s} does not tell speakers apart: its octoii.speakers is false", .{reference});
    if (request.response_format) |format| if (model.octoii.response_formats) |formats| {
        for (formats) |each| {
            if (std.mem.eql(u8, @tagName(each), @tagName(format))) break;
        } else {
            var names: std.ArrayList([]const u8) = .empty;
            for (formats) |each| try names.append(call.arena, @tagName(each));
            return call.failWith(.invalid_request, "The model {s} does not answer in {t}: its octoii.response_formats list {s}", .{ reference, format, try std.mem.join(call.arena, ", ", names.items) });
        }
    };
    const verbose = request.response_format == .verbose_json;
    const timed = if (request.timestamp_granularities) |given| given.len > 0 else false;
    if (!verbose and (diarized or timed)) {
        return call.failWith(.invalid_request, "timestamp_granularities and diarize ask for what only verbose_json holds: set response_format to verbose_json", .{});
    }
}

/// Drives `stream` to its end: the transcription its end carries, its text and usage, the rest of the response, and
/// Octoii's account; or the failure it ended with.
pub fn gathered(arena: Allocator, stream: *TranscriptionStream) Allocator.Error!stream_.Outcome(transcriptions.TranscriptionResponse) {
    defer stream.close();
    var done: ?transcriptions.TranscriptTextDoneEvent = null;
    while (try stream.next()) |event| switch (event) {
        .@"error" => return .{ .failed = stream.failure.? },
        .done => |given| done = given,
        else => {},
    };
    if (stream.failure) |failure| return .{ .failed = failure };
    const ended = done orelse return stream_.failedWith(transcriptions.TranscriptionResponse, arena, .invalid_response, "The stream ended without its transcript.text.done", .{});
    const extension = ended.octoii orelse @TypeOf(ended.octoii.?){};
    const details = extension.transcription orelse transcriptions.TranscriptionDetails{};
    var response: transcriptions.TranscriptionResponse = .{ .text = ended.text, .usage = ended.usage, .octoii = if (extension.usage) |given| .{ .usage = given } else null };
    inline for (comptime std.meta.fieldNames(transcriptions.TranscriptionDetails)) |name| @field(response, name) = @field(details, name);
    return .{ .made = response };
}
