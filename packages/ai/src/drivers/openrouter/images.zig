//! OpenRouter's image kind: its image API, which the vocabulary is, at `/images`. A model that streams is asked for a
//! stream of server-sent events, which come back as they are but for their errors; one that does not answers with
//! JSON, each image of which is an `image_generation.completed`, the usage on the last.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const images = vocabulary.images;
const Event = images.ImageStreamEvent;
const seam = @import("../../driver.zig");
const Call = seam.Call;
const failure_ = @import("../../failure.zig");
const Error = failure_.Error;
const Model = @import("../../catalogue/model.zig").Model;
const source = @import("../../wire/source.zig");
const media = @import("media.zig");

/// The routing an image request takes at OpenRouter.
const routing = [_][]const u8{ "only", "order", "ignore", "sort", "allow_fallbacks", "options" };

/// The request as it goes to OpenRouter for `model`: the model by its id, no extensions, as a stream where the model
/// streams.
pub fn wireRequest(arena: Allocator, model: *const Model, request: images.ImageRequest) Allocator.Error![]const u8 {
    var sent = request;
    if (request.input_references) |given| {
        const plain = try arena.dupe(vocabulary.media.ImageReference, given);
        for (plain) |*reference| reference.octoii = null;
        sent.input_references = plain;
    }
    sent.model = model.id;
    return foundation.json.encode(arena, foundation.json.merged(.{ sent, .{ .stream = if (model.supports_streaming == true) true else null } }));
}

pub fn make(call: *Call, model: *const Model, request: *const images.ImageRequest) Error!seam.ImageSource {
    try media.checkProviderFields(call, request.provider, &routing, "image API");
    const streaming = model.supports_streaming == true;
    const response = try media.send(call, "/images", try wireRequest(call.arena, model, request.*), if (streaming) "text/event-stream" else "application/json");
    if (media.streams(response)) return source.of(Event, call, response, translate);
    return source.listed(Event, call, try completedEvents(call.arena, try media.jsonBody(images.ImageResponse, call, response, "images")));
}

/// The event of the vocabulary one event of OpenRouter's image stream stands for.
fn translate(call: *Call, data: []const u8, out: *std.ArrayList(Event)) Error!void {
    if (try media.errorEvent(call.arena, data)) |raised| return out.append(call.arena, .{ .@"error" = raised });
    const event = foundation.json.decode(Event, call.arena, data) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            var failure: failure_.Failure = .init(.invalid_response, "The provider sent an event outside the vocabulary of images");
            failure.body = data;
            return call.fail(failure);
        },
    };
    try out.append(call.arena, event);
}

/// The images of a response that does not stream, each completed, the response's usage on the last.
fn completedEvents(arena: Allocator, response: images.ImageResponse) Allocator.Error![]const Event {
    const made = try arena.alloc(Event, response.data.len);
    for (response.data, made, 0..) |image, *event, index| event.* = .{ .completed = .{
        .b64_json = image.b64_json,
        .media_type = image.media_type,
        .created = response.created,
        .usage = if (index == response.data.len - 1) response.usage else null,
    } };
    return made;
}
