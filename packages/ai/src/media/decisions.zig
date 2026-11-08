//! The decision kind as `Models` serves it: a request checked against its model, the images, audio and video in its
//! state and questions read into inline data, stored or at an address, then answered by its provider, the answer
//! priced.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const decisions = vocabulary.decisions;
const driver = @import("../driver.zig");
const Call = driver.Call;
const Error = @import("../failure.zig").Error;
const model_ = @import("../catalogue/model.zig");
const Model = model_.Model;
const Models = @import("../Models.zig");
const check = @import("../text/check.zig");
const stream_ = @import("stream.zig");
const references = @import("references.zig");
const usage = @import("usage.zig");
const text_stream = @import("../text/stream.zig");

/// The answers to `request`'s questions, priced, or the failure it ended with.
pub fn decide(models: *Models, arena: Allocator, request: decisions.DecisionsRequest) Allocator.Error!stream_.Outcome(decisions.DecisionsResponse) {
    var call: Call = .{ .arena = arena, .provider = undefined, .host = &models.host, .wait = .{ .head_ms = text_stream.start_timeout_ms, .idle_ms = text_stream.idle_timeout_ms } };
    const response = decided(models, &call, request) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => return .{ .failed = call.failure.? },
    };
    return .{ .made = response };
}

fn decided(models: *Models, call: *Call, request: decisions.DecisionsRequest) Error!decisions.DecisionsResponse {
    const found = try models.served(call, request.model, .decision);
    call.provider = found.provider;
    const answer = found.provider.driver.decision orelse return call.failWith(.invalid_request, "The provider {s} answers no decisions", .{found.provider.id});
    const model = try call.arena.create(Model);
    model.* = found.model;
    const sent_at_ms = call.nowMs();
    try checkQuestions(call, model, &request);
    var reading: Reading = .{ .call = call };
    var prepared = request;
    prepared.state = try reading.media(request.state, "the state");
    var questions: std.json.ArrayHashMap(decisions.DecisionsQuestion) = .{};
    var it = request.questions.map.iterator();
    while (it.next()) |entry| try questions.map.put(call.arena, entry.key_ptr.*, try reading.question(entry.value_ptr.*, try std.fmt.allocPrint(call.arena, "the question {s}", .{entry.key_ptr.*})));
    prepared.questions = questions;
    inline for (.{ .image, .audio, .video }) |modality| if (@field(reading.found, @tagName(modality)) and !model.reads(modality)) {
        return call.failWith(.invalid_request, "The request holds " ++ @tagName(modality) ++ " in its state or questions, and the model {s} does not read " ++ @tagName(modality) ++ ": its architecture.input_modalities lack it", .{try model.reference(call.arena)});
    };
    try check.withinInputLimits(call, model, prepared, reading.images.items);
    var response = try answer(call, model, &prepared);
    const given = if (response.octoii) |extension| extension.usage else null;
    const meters = given orelse vocabulary.Usage{ .input = usage.counted(response.usage.input_tokens), .output = usage.counted(response.usage.output_tokens) };
    response.octoii = .{ .usage = usage.priced(model, meters, response.usage.cost, sent_at_ms) };
    return response;
}

/// Checks that a box question goes only to a model that answers them.
fn checkQuestions(call: *Call, model: *const Model, request: *const decisions.DecisionsRequest) Error!void {
    if (model.octoii.box == true) return;
    var it = request.questions.map.iterator();
    while (it.next()) |entry| if (entry.value_ptr.* == .box) {
        return call.failWith(.invalid_request, "The model {s} answers no box questions, as {s} is: its octoii.box is not true", .{ try model.reference(call.arena), entry.key_ptr.* });
    };
}

/// The media a request's texts hold, read as they are found.
const Reading = struct {
    call: *Call,
    found: struct { image: bool = false, audio: bool = false, video: bool = false } = .{},
    /// The base64 of each image inline after reading.
    images: std.ArrayList(?[]const u8) = .empty,

    /// A question with the media of its instructions and criteria read.
    fn question(reading: *Reading, given: decisions.DecisionsQuestion, where: []const u8) Error!decisions.DecisionsQuestion {
        var read = given;
        switch (read) {
            inline else => |*each| each.instructions = try reading.media(each.instructions, where),
        }
        switch (read) {
            .box => {},
            .noul => |*noul| if (noul.criteria) |*criteria| {
                criteria.true = try reading.media(criteria.true, where);
                criteria.false = try reading.media(criteria.false, where);
            },
            .choice => |*choice| {
                var it = choice.criteria.map.iterator();
                while (it.next()) |entry| entry.value_ptr.* = try reading.media(entry.value_ptr.*, where);
            },
            .score => |*score| {
                const criteria = try reading.call.arena.dupe(Value, score.criteria);
                for (criteria) |*text| text.* = try reading.media(text.*, where);
                score.criteria = criteria;
            },
        }
        return read;
    }

    /// `value` with each image, audio and video item in it, at any depth, read: images and video into data URLs, audio
    /// into base64 data, each without Octoii's `octoii`.
    fn media(reading: *Reading, value: Value, where: []const u8) Error!Value {
        const call = reading.call;
        const arena = call.arena;
        switch (value) {
            .array => |list| {
                var read = std.json.Array.init(arena);
                for (list.items) |each| try read.append(try reading.media(each, where));
                return .{ .array = read };
            },
            .object => |object| {
                const what = try std.fmt.allocPrint(arena, "An item of {s}", .{where});
                if (decode(vocabulary.media.ImageReference, arena, value)) |image| {
                    reading.found.image = true;
                    const file = try references.read(call, .image, .{ .url = image.image_url.url, .octoii = image.octoii }, true, what);
                    try reading.images.append(arena, references.dataUrlBase64(file.url));
                    return foundation.json.toValue(arena, vocabulary.media.ImageReference{ .image_url = .{ .url = file.url } });
                }
                if (decode(vocabulary.media.VideoReference, arena, value)) |video| {
                    reading.found.video = true;
                    const file = try references.read(call, .video, .{ .url = video.video_url.url, .octoii = video.octoii }, true, what);
                    return foundation.json.toValue(arena, vocabulary.media.VideoReference{ .video_url = .{ .url = file.url } });
                }
                if (decode(vocabulary.media.AudioInput, arena, value)) |sound| return reading.audio(sound, what);
                var read: std.json.ObjectMap = .empty;
                var it = object.iterator();
                while (it.next()) |entry| try read.put(arena, entry.key_ptr.*, try reading.media(entry.value_ptr.*, where));
                return .{ .object = read };
            },
            else => return value,
        }
    }

    fn audio(reading: *Reading, given: vocabulary.media.AudioInput, what: []const u8) Error!Value {
        const call = reading.call;
        reading.found.audio = true;
        const stored = if (given.octoii) |extension| extension.ref != null else false;
        if (!stored and given.input_audio.url == null) {
            const data = given.input_audio.data orelse return call.failWith(.invalid_request, "{s} holds no audio: give its data, its url, or a stored file as octoii.ref", .{what});
            return foundation.json.toValue(call.arena, vocabulary.media.AudioInput{ .input_audio = .{ .data = data, .format = given.input_audio.format } });
        }
        const read = try references.readAudio(call, .{ .url = given.input_audio.url, .octoii = given.octoii }, true, what);
        return foundation.json.toValue(call.arena, vocabulary.media.AudioInput{ .input_audio = .{ .data = read.data, .format = given.input_audio.format orelse references.audioFormat(read.media_type) } });
    }
};

/// `value` as `T` where it is one; null otherwise.
fn decode(comptime T: type, arena: Allocator, value: Value) ?T {
    return foundation.json.decodeValue(T, arena, value) catch null;
}
