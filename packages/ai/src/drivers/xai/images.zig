//! xAI's image kind: its image API, at `/images/generations`, or with references at `/images/edits`. Every image comes
//! back as base64 and is completed in turn, the usage of them all on the last: the images made, priced by the image,
//! with xAI's cost from its ticks.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const images = vocabulary.images;
const Event = images.ImageStreamEvent;
const seam = @import("../../driver.zig");
const Call = seam.Call;
const Error = @import("../../failure.zig").Error;
const Model = @import("../../catalogue/model.zig").Model;
const source = @import("../../wire/source.zig");
const usage_ = @import("../../media/usage.zig");
const media = @import("media.zig");

/// A reference as xAI takes it.
const Reference = struct { url: []const u8 };

/// The body of a request to xAI's image API.
const Body = struct {
    model: []const u8,
    prompt: []const u8,
    n: ?u32 = null,
    aspect_ratio: ?[]const u8 = null,
    resolution: ?[]const u8 = null,
    quality: @FieldType(images.ImageRequest, "quality") = null,
    user: ?[]const u8 = null,
    image: ?Reference = null,
    images: ?[]const Reference = null,
};

/// The request as it goes to xAI for `model`, and the path it goes to: the model by its id, the resolution in lower
/// case, references as the edit's `image` or `images`, its options among its fields, and the images asked for as
/// base64; `invalid_request` for a reference of a type xAI does not read, or a `provider` field but its options.
pub fn wireRequest(call: *Call, model: *const Model, request: images.ImageRequest) Error!struct { path: []const u8, body: []const u8 } {
    const own = try media.options(call, request.provider, "image API");
    const given = request.input_references orelse &.{};
    const references = try call.arena.alloc(Reference, given.len);
    for (given, references, 0..) |reference, *each, index| {
        try media.checkImageType(call, reference.image_url.url, reference.octoii, try call.arena.print("The input_references[{d}]", .{index}));
        each.* = .{ .url = reference.image_url.url orelse "" };
    }
    const body: Body = .{
        .model = model.id,
        .prompt = request.prompt,
        .n = request.n,
        .aspect_ratio = request.aspect_ratio,
        .resolution = if (request.resolution) |resolution| try std.ascii.allocLowerString(call.arena, resolution) else null,
        .quality = request.quality,
        .user = request.user,
        .image = if (references.len == 1) references[0] else null,
        .images = if (references.len > 1) references else null,
    };
    return .{
        .path = if (references.len == 0) "/images/generations" else "/images/edits",
        .body = try foundation.json.encode(call.arena, foundation.json.merged(.{ body, own, .{ .response_format = "b64_json" } })),
    };
}

/// What xAI's images answer with, of which ai reads these fields.
const Answer = struct {
    data: []const struct { b64_json: ?[]const u8 = null, mime_type: ?[]const u8 = null },
    usage: ?struct {
        cost_in_usd_ticks: ?u64 = null,
        input_tokens: ?u64 = null,
        input_tokens_details: ?struct { cached_tokens: ?u64 = null } = null,
        output_tokens: ?u64 = null,
        output_tokens_details: ?struct { image_tokens: ?u64 = null, reasoning_tokens: ?u64 = null } = null,
        total_tokens: ?u64 = null,
    } = null,
};

pub fn make(call: *Call, model: *const Model, request: *const images.ImageRequest) Error!seam.ImageSource {
    const wire = try wireRequest(call, model, request.*);
    const response = try media.send(call, .{ .path = wire.path, .body = wire.body, .accept = "application/json" });
    const answer = try media.jsonBody(Answer, call, response, "images");
    const created = @divFloor(call.nowMs(), 1000);
    const read = if (request.input_references) |given| given.len else 0;
    const made = try call.arena.alloc(Event, answer.data.len);
    for (answer.data, made, 0..) |image, *event, index| {
        const b64 = image.b64_json orelse return call.failWith(.invalid_response, "xAI answered with an image without its base64", .{});
        event.* = .{ .completed = .{ .b64_json = b64, .media_type = image.mime_type, .created = created } };
        if (index == answer.data.len - 1) withUsage(&event.completed, answer, read);
    }
    return source.listed(Event, call, made);
}

/// `completed`, the last image, with the usage of every image: xAI's in the vocabulary's shape, and ai's account by
/// the image, with xAI's cost.
fn withUsage(completed: *images.ImageCompletedEvent, answer: Answer, read: usize) void {
    const cost = if (answer.usage) |given| (if (given.cost_in_usd_ticks) |ticks| media.dollarsOfTicks(ticks) else null) else null;
    completed.octoii = .{ .usage = .{ .images_made = answer.data.len, .images_read = usage_.counted(read), .cost = cost } };
    const given = answer.usage orelse return;
    const input = given.input_tokens orelse 0;
    const output = given.output_tokens orelse 0;
    completed.usage = .{
        .prompt_tokens = input,
        .completion_tokens = output,
        .total_tokens = given.total_tokens orelse input + output,
        .prompt_tokens_details = if (given.input_tokens_details) |details| (if (details.cached_tokens) |cached| .{ .cached_tokens = cached } else null) else null,
        .completion_tokens_details = if (given.output_tokens_details) |details| .{ .image_tokens = details.image_tokens, .reasoning_tokens = details.reasoning_tokens } else null,
        .cost = cost,
    };
}
