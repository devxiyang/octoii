//! The image kind as `Models` serves it: a request checked against its model — its references read where the model
//! reads images, each setting its `octoii.image_parameters` describe within them — its stored references read, sent to
//! its provider's stream, each image made priced; and, to generate, the stream gathered into the whole response.
const std = @import("std");
const Allocator = std.mem.Allocator;
const vocabulary = @import("vocabulary");
const images = vocabulary.images;
const ImageRequest = images.ImageRequest;
const Usage = vocabulary.Usage;
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

/// A request of the image kind, as its stream sends it.
pub const Images = struct {
    pub const Event = images.ImageStreamEvent;
    pub const last = std.meta.Tag(Event).completed;

    models: *Models,
    request: ImageRequest,
    /// The model the request was sent to, and when, which price each image made.
    model: ?*const Model = null,
    sent_at_ms: i64 = 0,

    pub fn begin(kind: *Images, call: *Call) Error!driver.ImageSource {
        const served = try kind.models.served(call, kind.request.model, .image);
        call.provider = served.provider;
        const make = served.provider.driver.image orelse return call.failWith(.invalid_request, "The provider {s} makes no images", .{served.provider.id});
        const model = try call.arena.create(Model);
        model.* = served.model;
        kind.model = model;
        kind.sent_at_ms = call.nowMs();
        try checkRequest(call, model, &kind.request);
        const prepared = try call.arena.create(ImageRequest);
        prepared.* = try withReferencesRead(call, model, kind.request);
        return make(call, model, prepared);
    }

    /// A completed image with Octoii's account of what made it: the meters its provider gave, else its usage's,
    /// priced.
    pub fn finish(kind: *Images, _: Allocator, event: Event) Allocator.Error!Event {
        if (event != .completed) return event;
        var completed = event.completed;
        const given = if (completed.octoii) |extension| extension.usage else null;
        const meters = given orelse usage.imageMeters(completed.usage);
        const cost = if (completed.usage) |reported| reported.cost else null;
        completed.octoii = .{ .usage = usage.priced(kind.model.?, meters, cost, kind.sent_at_ms) };
        return .{ .completed = completed };
    }
};

pub const ImageStream = stream_.Stream(Images);

/// The settings of an image request a model's `octoii.image_parameters` describe, by the name they describe them under.
const settings = [_][]const u8{ "n", "resolution", "aspect_ratio", "size", "quality", "output_format", "background", "output_compression", "seed" };

/// Checks `request` against `model`: references for a model that reads images, and each setting its
/// `octoii.image_parameters` describe, where it has them, the count of `input_references` among them.
fn checkRequest(call: *Call, model: *const Model, request: *const ImageRequest) Error!void {
    const reference = try model.reference(call.arena);
    const count = if (request.input_references) |given| given.len else 0;
    if (count > 0 and !model.reads(.image)) {
        return call.failWith(.invalid_request, "The request holds input_references, and the model {s} does not read image: its architecture.input_modalities lack it", .{reference});
    }
    const parameters = model.octoii.image_parameters orelse return;
    inline for (settings) |name| if (@field(request, name)) |value| {
        try checkSetting(call, reference, name, settingValue(value), parameters.map.get(name));
    };
    if (count > 0) try checkSetting(call, reference, "input_references", .{ .number = @floatFromInt(count) }, parameters.map.get("input_references"));
}

/// A setting's value, as a range checks it: text, or a number.
const Value = union(enum) {
    text: []const u8,
    number: f64,

    pub fn format(value: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (value) {
            .text => |text| try writer.print("\"{s}\"", .{text}),
            .number => |number| try writer.print("{d}", .{number}),
        }
    }
};

fn settingValue(value: anytype) Value {
    return switch (@typeInfo(@TypeOf(value))) {
        .int => .{ .number = @floatFromInt(value) },
        .@"enum" => .{ .text = @tagName(value) },
        else => .{ .text = value },
    };
}

/// Checks one setting's `value` against the range the model describes it by.
fn checkSetting(call: *Call, reference: []const u8, name: []const u8, value: Value, range: ?model_.ParameterRange) Error!void {
    const described = range orelse return call.failWith(.invalid_request, "The model {s} does not take {s}: its octoii.image_parameters do not list it", .{ reference, name });
    switch (described) {
        .boolean => {},
        .@"enum" => |listed| {
            var buffer: [32]u8 = undefined;
            const text = switch (value) {
                .text => |given| given,
                .number => |number| std.fmt.bufPrint(&buffer, "{d}", .{number}) catch "",
            };
            for (listed.values) |each| if (std.mem.eql(u8, each, text)) return;
            return call.failWith(.invalid_request, "The model {s} does not take the {s} {f}: it takes {s}", .{ reference, name, value, try std.mem.join(call.arena, ", ", listed.values) });
        },
        .range => |bounds| {
            const number = switch (value) {
                .number => |given| given,
                .text => null,
            };
            const within = if (number) |given| (bounds.min == null or given >= bounds.min.?) and (bounds.max == null or given <= bounds.max.?) else false;
            if (within) return;
            const min = if (bounds.min) |given| try call.arena.print("{d}", .{given}) else "any";
            const max = if (bounds.max) |given| try call.arena.print("{d}", .{given}) else "any";
            return call.failWith(.invalid_request, "The model {s} does not take the {s} {f}: it takes {s} to {s}", .{ reference, name, value, min, max });
        },
    }
}

/// `request` with its stored references read into data URLs, and its images within the model's limits.
fn withReferencesRead(call: *Call, model: *const Model, request: ImageRequest) Error!ImageRequest {
    const given = request.input_references orelse return request;
    const read = try call.arena.alloc(vocabulary.media.ImageReference, given.len);
    const encoded = try call.arena.alloc(?[]const u8, given.len);
    for (given, read, encoded, 0..) |reference, *made, *base64, index| {
        const what = try call.arena.print("The input_references[{d}]", .{index});
        const file = try references.read(call, .image, .{ .url = reference.image_url.url, .octoii = reference.octoii }, false, what);
        made.* = .{ .image_url = .{ .url = file.url }, .octoii = file.octoii };
        base64.* = references.dataUrlBase64(file.url);
    }
    var prepared = request;
    prepared.input_references = read;
    try check.withinInputLimits(call, model, prepared, encoded);
    return prepared;
}

/// Drives `stream` to its end: the images it made in order, `created` the first's, and their usages added; or the
/// failure it ended with.
pub fn gathered(arena: Allocator, stream: *ImageStream) Allocator.Error!stream_.Outcome(images.ImageResponse) {
    defer stream.close();
    var data: std.ArrayList(images.ImageData) = .empty;
    var created: ?i64 = null;
    var reported: ?images.ImageUsage = null;
    var account: Usage = .{};
    while (try stream.next()) |event| switch (event) {
        .@"error" => return .{ .failed = stream.failure.? },
        .completed => |completed| {
            try data.append(arena, .{ .b64_json = completed.b64_json, .media_type = completed.media_type });
            if (created == null) created = completed.created;
            if (completed.usage) |given| reported = if (reported) |sum| added(sum, given) else given;
            if (completed.octoii) |extension| if (extension.usage) |given| {
                account = account.add(given);
            };
        },
        else => {},
    };
    if (stream.failure) |failure| return .{ .failed = failure };
    const first = created orelse return stream_.failedWith(images.ImageResponse, arena, .invalid_response, "The stream ended without an image", .{});
    return .{ .made = .{ .created = first, .data = data.items, .usage = reported, .octoii = .{ .usage = account } } };
}

/// Two image usages added count by count, and their costs where they are there.
fn added(a: images.ImageUsage, b: images.ImageUsage) images.ImageUsage {
    const Details = struct {
        fn sum(left: ?u64, right: ?u64) ?u64 {
            if (left == null and right == null) return null;
            return (left orelse 0) + (right orelse 0);
        }
    };
    const a_prompt = a.prompt_tokens_details orelse @TypeOf(a.prompt_tokens_details.?){};
    const b_prompt = b.prompt_tokens_details orelse @TypeOf(b.prompt_tokens_details.?){};
    const a_completion = a.completion_tokens_details orelse @TypeOf(a.completion_tokens_details.?){};
    const b_completion = b.completion_tokens_details orelse @TypeOf(b.completion_tokens_details.?){};
    return .{
        .prompt_tokens = a.prompt_tokens + b.prompt_tokens,
        .completion_tokens = a.completion_tokens + b.completion_tokens,
        .total_tokens = a.total_tokens + b.total_tokens,
        .prompt_tokens_details = .{ .cached_tokens = Details.sum(a_prompt.cached_tokens, b_prompt.cached_tokens), .cache_write_tokens = Details.sum(a_prompt.cache_write_tokens, b_prompt.cache_write_tokens) },
        .completion_tokens_details = .{ .image_tokens = Details.sum(a_completion.image_tokens, b_completion.image_tokens), .reasoning_tokens = Details.sum(a_completion.reasoning_tokens, b_completion.reasoning_tokens) },
        .cost = if (a.cost == null and b.cost == null) null else (a.cost orelse 0) + (b.cost orelse 0),
    };
}
