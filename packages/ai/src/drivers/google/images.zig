//! Google's image kind: the Interactions API, asked for images alone. The prompt is a text input and each reference an
//! image input; the resolution, aspect ratio and seed are the image format's and the generation's. Each image made is
//! an `image_generation.completed`, the usage on the last; a thought's image is a preview and its text reasoning. A
//! request for `n` images is sent `n` times, as Gemini makes one image a request.
const std = @import("std");
const Allocator = std.mem.Allocator;
const vocabulary = @import("vocabulary");
const images = vocabulary.images;
const Event = images.ImageStreamEvent;
const seam = @import("../../driver.zig");
const Call = seam.Call;
const Error = @import("../../failure.zig").Error;
const Model = @import("../../catalogue/model.zig").Model;
const files = @import("../../text/files.zig");
const json = @import("../../wire/json.zig");
const interactions = @import("interactions.zig");
const Block = @import("request.zig").Block;

/// The settings of an image request Google has no field for.
const untaken = [_][]const u8{ "size", "quality", "output_format", "background", "output_compression" };

/// The interaction an image request asks Google for.
const Interaction = struct {
    model: []const u8,
    input: []const Block,
    response_format: struct { type: enum { image } = .image, image_size: ?[]const u8 = null, aspect_ratio: ?[]const u8 = null },
    generation_config: ?struct { seed: i64 } = null,
};

/// The body of the interaction `request` asks Google for: the prompt and the references as its input, images alone in
/// the format of its resolution and aspect ratio, and its seed; `invalid_request` for what Google does not take.
pub fn wireRequest(call: *Call, model: *const Model, request: images.ImageRequest) Error![]const u8 {
    inline for (untaken) |setting| if (@field(request, setting) != null) {
        return call.failWith(.invalid_request, "The model {s} cannot take " ++ setting ++ ": Google does not offer it", .{try model.reference(call.arena)});
    };
    const own = try json.ownOptionsAlone(call, request.provider, "google", "Google takes no routing preferences, such as {s}: its provider takes options alone");
    const references = request.input_references orelse &.{};
    const input = try call.arena.alloc(Block, references.len + 1);
    input[0] = .{ .text = .{ .text = request.prompt } };
    for (references, input[1..]) |reference, *each| {
        const file: files.TypedFile = .{ .input_image = .{ .detail = .auto, .image_url = reference.image_url.url orelse "", .octoii = reference.octoii } };
        const data = files.inlineBase64(file);
        each.* = .{ .image = .{ .data = data, .uri = if (data == null) reference.image_url.url else null, .mime_type = try files.mediaType(call.arena, file, null) } };
    }
    const interaction: Interaction = .{
        .model = model.id,
        .input = input,
        .response_format = .{ .image_size = request.resolution, .aspect_ratio = request.aspect_ratio },
        .generation_config = if (request.seed) |seed| .{ .seed = seed } else null,
    };
    return interactions.requestBody(call.arena, interaction, own);
}

pub fn make(call: *Call, model: *const Model, request: *const images.ImageRequest) Error!seam.ImageSource {
    const made = try call.arena.create(Source);
    made.* = .{ .call = call, .body = try wireRequest(call, model, request.*), .count = request.n orelse 1 };
    return .{ .context = made, .vtable = &.{ .next = Source.next, .close = Source.close } };
}

/// The images of a request, each of its `n` interactions in turn.
const Source = struct {
    call: *Call,
    body: []const u8,
    count: u32,
    sent: u32 = 0,
    reader: ?interactions.MadeReader = null,
    /// The previews given, numbered across the request.
    previews: u32 = 0,
    created: i64 = 0,
    /// The image made last, completed once the next comes or the interaction ends.
    made: ?images.ImageCompletedEvent = null,

    fn next(context: *anyopaque) Error!?Event {
        const source: *Source = @ptrCast(@alignCast(context));
        while (true) {
            const reader = &(source.reader orelse {
                if (source.sent == source.count) return null;
                source.sent += 1;
                source.created = @divFloor(source.call.nowMs(), 1000);
                source.reader = try .open(source.call, source.body);
                continue;
            });
            const event = try reader.next() orelse {
                reader.close();
                source.reader = null;
                continue;
            };
            if (try source.eventOf(event)) |given| return given;
        }
    }

    /// The event one of the interaction's stands for: each thought's image a preview, text as its chunks, and each
    /// image made completed once the next comes, the last with the interaction's usage.
    fn eventOf(source: *Source, event: interactions.Made) Error!?Event {
        switch (event) {
            .created => |created| source.created = created,
            .made => |made| {
                const content = made.content;
                if (std.mem.eql(u8, content.type, "text")) if (content.text) |text| if (text.len > 0) {
                    return .{ .text_chunk = .{ .text = text, .phase = if (made.thought) .reasoning else .content } };
                };
                if (!std.mem.eql(u8, content.type, "image")) return null;
                const data = content.data orelse return null;
                if (made.thought) {
                    defer source.previews += 1;
                    return .{ .partial_image = .{ .partial_image_index = source.previews, .b64_json = data } };
                }
                const previous = source.made;
                source.made = .{ .b64_json = data, .media_type = content.mime_type, .created = source.created };
                if (previous) |completed| return .{ .completed = completed };
            },
            .completed => |usage| {
                var completed = source.made orelse return source.call.failWith(.invalid_response, "The interaction completed without an image", .{});
                source.made = null;
                if (usage) |given| completed.usage = imageUsage(given);
                return .{ .completed = completed };
            },
        }
        return null;
    }

    fn close(context: *anyopaque) void {
        const source: *Source = @ptrCast(@alignCast(context));
        if (source.reader) |*reader| reader.close();
        source.reader = null;
    }
};

/// An interaction's usage as the image API's: the prompt's tokens read, the cached among them; the output's and the
/// thoughts' written, of which the images' and the thoughts' apart.
fn imageUsage(usage: interactions.Usage) images.ImageUsage {
    const input = usage.total_input_tokens orelse 0;
    const thoughts = usage.total_thought_tokens orelse 0;
    const output = (usage.total_output_tokens orelse 0) + thoughts;
    const cached = usage.total_cached_tokens orelse 0;
    return .{
        .prompt_tokens = input,
        .completion_tokens = output,
        .total_tokens = usage.total_tokens orelse input + output,
        .prompt_tokens_details = if (cached == 0) null else .{ .cached_tokens = cached },
        .completion_tokens_details = .{ .image_tokens = interactions.tokensOf(usage.output_tokens_by_modality, "image"), .reasoning_tokens = thoughts },
    };
}
