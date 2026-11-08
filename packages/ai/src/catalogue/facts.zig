//! What a model is like: each fact taken whole from the first source that gives it — the catalogue, the provider's
//! listing, the person, else what is assumed — and where each came from kept in `octoii.sources`. The facts assumed
//! are those a request needs to be fitted: its name, kinds, window, output and what it reads.
const std = @import("std");
const Allocator = std.mem.Allocator;
const model_ = @import("model.zig");
const Model = model_.Model;
const Kind = model_.Kind;

/// The window, in tokens, assumed of a model no source gives one for.
pub const assumed_context_tokens = 200_000;

/// The output, in tokens, assumed of a model no source gives one for.
pub const assumed_output_tokens = 32_000;

pub const Source = model_.Source;

/// What a listing or a person knows of one model: its id, and any of a model's facts, each left out where unknown.
pub const ModelFacts = struct {
    id: []const u8,
    name: ?[]const u8 = null,
    context_length: ?u64 = null,
    max_completion_tokens: ?u64 = null,
    architecture: ?@FieldType(Model, "architecture") = null,
    reasoning: ?model_.Reasoning = null,
    supported_parameters: ?[]const []const u8 = null,
    supported_voices: ?[]const []const u8 = null,
    pricing: ?model_.Pricing = null,
    supports_streaming: ?bool = null,
    supported_aspect_ratios: ?[]const []const u8 = null,
    supported_resolutions: ?[]const []const u8 = null,
    supported_sizes: ?[]const []const u8 = null,
    supported_durations: ?[]const f64 = null,
    supported_frame_images: ?[]const model_.FrameImage = null,
    generate_audio: ?bool = null,
    seed: ?bool = null,
    creativity: ?[]const f64 = null,
    upscale_factor: @FieldType(Model, "upscale_factor") = null,
    pricing_skus: ?std.json.ArrayHashMap([]const u8) = null,
    octoii: ?Octoii = null,

    pub const Octoii = struct {
        kinds: ?[]const Kind = null,
        release_date: ?[]const u8 = null,
        hosted_tools: ?@FieldType(model_.Facts, "hosted_tools") = null,
        input_limits: ?model_.InputLimits = null,
        features: ?model_.Features = null,
        preset_prompt: ?[]const u8 = null,
        image_parameters: ?std.json.ArrayHashMap(model_.ParameterRange) = null,
        instructions: ?bool = null,
        speakers: ?bool = null,
        response_formats: ?[]const model_.TranscriptionFormat = null,
        question_context_length: ?u64 = null,
        box: ?bool = null,
        realtime_pricing: ?model_.Pricing = null,
    };
};

/// The facts each source gives of one model, where it gives any.
pub const Given = struct {
    catalogue: ?Model = null,
    listing: ?ModelFacts = null,
    person: ?ModelFacts = null,
};

/// The model `id` of `provider`, which serves `kinds`, made of the facts `given` and those assumed where none gives one.
pub fn modelOf(arena: Allocator, provider: []const u8, id: []const u8, kinds: []const Kind, given: Given) Allocator.Error!Model {
    const assumed = try assumedFacts(arena, id, kinds);
    const layers = [_]struct { Source, ?ModelFacts }{
        .{ .catalogue, if (given.catalogue) |model| asFacts(model) else null },
        .{ .listing, given.listing },
        .{ .person, given.person },
        .{ .assumed, assumed },
    };
    var sources: std.json.ArrayHashMap(Source) = .{};
    var made: Model = .{ .id = id, .name = undefined, .architecture = undefined, .octoii = .{ .provider = provider, .kinds = undefined } };
    inline for (comptime std.meta.fieldNames(ModelFacts)) |field| {
        if (comptime std.mem.eql(u8, field, "id") or std.mem.eql(u8, field, "octoii")) continue;
        for (layers) |layer| {
            const facts = layer[1] orelse continue;
            const value = @field(facts, field) orelse continue;
            @field(made, field) = value;
            try sources.map.put(arena, field, layer[0]);
            break;
        }
    }
    inline for (comptime std.meta.fieldNames(ModelFacts.Octoii)) |field| {
        for (layers) |layer| {
            const facts = layer[1] orelse continue;
            const octoii = facts.octoii orelse continue;
            const value = @field(octoii, field) orelse continue;
            @field(made.octoii, field) = value;
            try sources.map.put(arena, "octoii." ++ field, layer[0]);
            break;
        }
    }
    made.octoii.sources = sources;
    return made;
}

/// A catalogue's model as facts a source gives.
pub fn asFacts(model: Model) ModelFacts {
    var facts: ModelFacts = .{ .id = model.id };
    inline for (comptime std.meta.fieldNames(ModelFacts)) |field| {
        if (comptime std.mem.eql(u8, field, "id") or std.mem.eql(u8, field, "octoii")) continue;
        @field(facts, field) = @field(model, field);
    }
    var octoii: ModelFacts.Octoii = .{};
    inline for (comptime std.meta.fieldNames(ModelFacts.Octoii)) |field| @field(octoii, field) = @field(model.octoii, field);
    facts.octoii = octoii;
    return facts;
}

/// The facts assumed of the model `id`, which serves `kinds`: its name, kinds, window, output and what it reads.
fn assumedFacts(arena: Allocator, id: []const u8, kinds: []const Kind) Allocator.Error!ModelFacts {
    var inputs: std.ArrayList(model_.InputModality) = .empty;
    var outputs: std.ArrayList(model_.OutputModality) = .empty;
    for (kinds) |kind| {
        const reads: []const model_.InputModality = switch (kind) {
            .text, .image, .video, .decision => &.{ .text, .image },
            .live, .transcription, .@"realtime-transcription" => &.{.audio},
            .speech => &.{.text},
        };
        for (reads) |modality| if (std.mem.indexOfScalar(model_.InputModality, inputs.items, modality) == null) try inputs.append(arena, modality);
        const makes: model_.OutputModality = switch (kind) {
            .text => .text,
            .live => .audio,
            .image => .image,
            .video => .video,
            .speech => .speech,
            .transcription, .@"realtime-transcription" => .transcription,
            .decision => .decisions,
        };
        if (std.mem.indexOfScalar(model_.OutputModality, outputs.items, makes) == null) try outputs.append(arena, makes);
    }
    return .{
        .id = id,
        .name = id,
        .context_length = assumed_context_tokens,
        .max_completion_tokens = assumed_output_tokens,
        .architecture = .{ .input_modalities = inputs.items, .output_modalities = outputs.items },
        .octoii = .{ .kinds = kinds },
    };
}

test "each fact comes whole from the first source that gives it, and its source is kept" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const listed: ModelFacts = .{ .id = "m", .name = "Listed", .context_length = 64_000 };
    const person: ModelFacts = .{ .id = "m", .name = "Mine", .max_completion_tokens = 8000, .octoii = .{ .release_date = "2026-10-01" } };
    const model = try modelOf(a, "local", "m", &.{.text}, .{ .listing = listed, .person = person });
    try std.testing.expectEqualStrings("Listed", model.name);
    try std.testing.expectEqual(@as(?u64, 64_000), model.context_length);
    try std.testing.expectEqual(@as(?u64, 8000), model.max_completion_tokens);
    try std.testing.expectEqualStrings("2026-10-01", model.octoii.release_date.?);
    try std.testing.expectEqualStrings("local", model.octoii.provider);
    try std.testing.expectEqual(Kind.text, model.octoii.kinds[0]);
    const sources = model.octoii.sources.?.map;
    try std.testing.expectEqual(Source.listing, sources.get("name").?);
    try std.testing.expectEqual(Source.person, sources.get("max_completion_tokens").?);
    try std.testing.expectEqual(Source.assumed, sources.get("architecture").?);
    try std.testing.expectEqual(Source.assumed, sources.get("octoii.kinds").?);
}
