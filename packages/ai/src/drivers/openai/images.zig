//! OpenAI's image kind: its image API, a request without references at `/images/generations` and one with them at
//! `/images/edits`, as JSON. A model that streams is asked for server-sent events, its edit events named as its
//! generation events are; one that does not answers with JSON, each image of which is an `image_generation.completed`,
//! the usage on the last. Its usage counts text and images apart, so each image made carries OpenAI's own meters.
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
const usage_ = @import("../../media/usage.zig");
const media = @import("media.zig");

/// The format of the images OpenAI makes where a request names none.
const default_format = "png";

/// The body of a request to OpenAI's image API: the settings it takes as the vocabulary gives them, the references as
/// its `images`.
const Body = struct {
    prompt: []const u8,
    n: ?u32 = null,
    size: ?[]const u8 = null,
    quality: @FieldType(images.ImageRequest, "quality") = null,
    background: @FieldType(images.ImageRequest, "background") = null,
    output_format: @FieldType(images.ImageRequest, "output_format") = null,
    output_compression: ?u32 = null,
    images: ?[]const Reference = null,

    const Reference = struct { image_url: []const u8 };
};

/// The request as it goes to OpenAI for `model`: the model by its id, the settings it takes, the references as its
/// `images`, OpenAI's own options, and a stream where the model streams; `invalid_request` for a setting it lacks.
pub fn wireRequest(call: *Call, model: *const Model, request: images.ImageRequest) Error![]const u8 {
    inline for (.{ "resolution", "aspect_ratio", "seed" }) |field| if (@field(request, field) != null) {
        return call.failWith(.invalid_request, "OpenAI's image API takes no " ++ field ++ ": give the image's size instead", .{});
    };
    const own = try media.options(call, request.provider, "image API");
    var body: Body = .{ .prompt = request.prompt, .n = request.n, .size = request.size, .quality = request.quality, .background = request.background, .output_format = request.output_format, .output_compression = request.output_compression };
    if (request.input_references) |given| if (given.len > 0) {
        const made = try call.arena.alloc(Body.Reference, given.len);
        for (given, made) |reference, *each| each.* = .{ .image_url = reference.image_url.url orelse "" };
        body.images = made;
    };
    return foundation.json.encode(call.arena, foundation.json.merged(.{ body, own, .{ .model = model.id, .stream = if (model.supports_streaming == true) true else null } }));
}

pub fn make(call: *Call, model: *const Model, request: *const images.ImageRequest) Error!seam.ImageSource {
    const body = try wireRequest(call, model, request.*);
    const edits = if (request.input_references) |given| given.len > 0 else false;
    const streaming = model.supports_streaming == true;
    const response = try media.send(call, .{ .path = if (edits) "/images/edits" else "/images/generations", .accept = if (streaming) "text/event-stream" else "application/json", .body = body });
    const format = if (request.output_format) |given| @tagName(given) else default_format;
    if (media.streams(response)) {
        const Translator = struct {
            fn translate(given: *Call, data: []const u8, out: *std.ArrayList(Event)) Error!void {
                try out.append(given.arena, try eventOf(given, data));
            }
        };
        return source.of(Event, call, response, Translator.translate);
    }
    const answer = try media.jsonBody(WireImagesResponse, call, response, "images");
    const made = try call.arena.alloc(Event, answer.data.len);
    for (answer.data, made, 0..) |image, *event, index| {
        event.* = .{ .completed = try completed(call.arena, image.b64_json, answer.output_format orelse format, answer.created, if (index == answer.data.len - 1) answer.usage else null) };
    }
    return source.listed(Event, call, made);
}

/// What making images used, as OpenAI's image API reports it.
const WireUsage = struct {
    input_tokens: u64,
    output_tokens: u64,
    total_tokens: u64,
    input_tokens_details: ?struct { text_tokens: ?u64 = null, image_tokens: ?u64 = null } = null,
    output_tokens_details: ?struct { text_tokens: ?u64 = null, image_tokens: ?u64 = null } = null,

    /// The output split into the images made and any text written; without details, all of it is images.
    fn made(given: WireUsage) struct { images: u64, text: u64 } {
        const details = given.output_tokens_details orelse @TypeOf(given.output_tokens_details.?){};
        const text = details.text_tokens orelse 0;
        return .{ .images = details.image_tokens orelse given.output_tokens -| text, .text = text };
    }
};

/// OpenAI's answer to a request that does not stream.
const WireImagesResponse = struct {
    created: i64,
    data: []const struct { b64_json: []const u8 },
    output_format: ?[]const u8 = null,
    usage: ?WireUsage = null,
};

/// An event of OpenAI's generation or edit stream, as far as it is read.
const WireEvent = struct {
    type: []const u8,
    b64_json: ?[]const u8 = null,
    partial_image_index: ?u32 = null,
    created_at: ?i64 = null,
    output_format: ?[]const u8 = null,
    usage: ?WireUsage = null,
};

/// The format the stream's images are of, where its events name none; OpenAI names it on each.
fn eventOf(call: *Call, data: []const u8) Error!Event {
    const value = std.json.parseFromSliceLeaky(std.json.Value, call.arena, data, .{ .allocate = .alloc_always }) catch return unknown(call, data);
    const event = foundation.json.decodeValue(WireEvent, call.arena, value) catch return unknown(call, data);
    if (std.mem.eql(u8, event.type, "error")) return .{ .@"error" = media.errorEvent(call.arena, value) orelse return unknown(call, data) };
    const b64 = event.b64_json orelse return unknown(call, data);
    if (std.mem.eql(u8, event.type, "image_generation.partial_image") or std.mem.eql(u8, event.type, "image_edit.partial_image")) {
        return .{ .partial_image = .{ .partial_image_index = event.partial_image_index orelse return unknown(call, data), .b64_json = b64 } };
    }
    if (std.mem.eql(u8, event.type, "image_generation.completed") or std.mem.eql(u8, event.type, "image_edit.completed")) {
        return .{ .completed = try completed(call.arena, b64, event.output_format orelse default_format, event.created_at orelse 0, event.usage) };
    }
    return unknown(call, data);
}

fn unknown(call: *Call, data: []const u8) Error {
    var failure: failure_.Failure = .init(.invalid_response, "The provider sent an image event ai does not know");
    failure.body = data;
    return call.fail(failure);
}

/// An `image_generation.completed` of `b64_json`, its usage in the vocabulary's shape and OpenAI's meters as ai's
/// account.
fn completed(arena: Allocator, b64_json: []const u8, format: []const u8, created: i64, usage: ?WireUsage) Allocator.Error!images.ImageCompletedEvent {
    var event: images.ImageCompletedEvent = .{ .b64_json = b64_json, .media_type = try std.fmt.allocPrint(arena, "image/{s}", .{format}), .created = created };
    const given = usage orelse return event;
    const made = given.made();
    event.usage = .{ .prompt_tokens = given.input_tokens, .completion_tokens = given.output_tokens, .total_tokens = given.total_tokens, .completion_tokens_details = .{ .image_tokens = made.images } };
    // OpenAI counts text and images apart: without details, an image model reads a prompt and makes images.
    const read = given.input_tokens_details orelse @TypeOf(given.input_tokens_details.?){};
    const images_read = read.image_tokens orelse 0;
    event.octoii = .{ .usage = .{
        .input = usage_.counted(read.text_tokens orelse given.input_tokens -| images_read),
        .input_image = usage_.counted(images_read),
        .output_image = usage_.counted(made.images),
        .output = usage_.counted(made.text),
    } };
    return event;
}
