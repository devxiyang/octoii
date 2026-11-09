//! A model as the catalogue describes it: the fields of OpenRouter's model listings and Octoii's own facts under
//! `octoii`. A model is named by its reference, `provider/id`. Models are data: no code tells one model from another by
//! its id, but by these facts. A field left out is unknown.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const Raw = foundation.json.Raw;
const vocabulary = @import("vocabulary");
const ReasoningEffort = vocabulary.items.ReasoningEffort;

/// What a model does, which decides the calls it serves.
pub const Kind = enum { text, live, image, video, speech, transcription, @"realtime-transcription", decision };

/// What a model reads.
pub const InputModality = enum { text, image, file, audio, video };

/// What a model makes.
pub const OutputModality = enum { text, image, audio, video, speech, transcription, decisions };

pub const Model = struct {
    /// The provider's id of the model, as its requests name it.
    id: []const u8,
    /// For people, such as "Claude Opus 5.5".
    name: []const u8,
    /// The tokens a request and its response may take together.
    context_length: ?u64 = null,
    /// The tokens a response may take, at the model's provider.
    max_completion_tokens: ?u64 = null,
    architecture: struct {
        input_modalities: []const InputModality,
        output_modalities: []const OutputModality,
    },
    /// How the model reasons, for a model whose `supported_parameters` list `reasoning`.
    reasoning: ?Reasoning = null,
    /// The request fields it takes, as OpenRouter names them, such as "temperature" or "structured_outputs".
    supported_parameters: ?[]const []const u8 = null,
    /// A speech or live model's own voices.
    supported_voices: ?[]const []const u8 = null,
    /// Its prices; left out for a model that cannot be priced, such as one a subscription pays for.
    pricing: ?Pricing = null,
    /// An image model's, and a transcription model's: whether it streams previews of its images, or its transcript
    /// as it is written.
    supports_streaming: ?bool = null,
    /// A video model's, as OpenRouter's video listing gives them.
    supported_aspect_ratios: ?[]const []const u8 = null,
    supported_resolutions: ?[]const []const u8 = null,
    supported_sizes: ?[]const []const u8 = null,
    /// In seconds.
    supported_durations: ?[]const f64 = null,
    supported_frame_images: ?[]const FrameImage = null,
    /// Whether it makes sound with its videos.
    generate_audio: ?bool = null,
    /// Whether it takes a seed.
    seed: ?bool = null,
    /// An upscaling model's levels.
    creativity: ?[]const f64 = null,
    /// An upscaling model's factors.
    upscale_factor: ?struct { min: ?f64 = null, max: ?f64 = null } = null,
    /// Its prices under its provider's names, such as "duration_seconds_with_audio".
    pricing_skus: ?std.json.ArrayHashMap([]const u8) = null,
    octoii: Facts,

    /// The model's reference, `provider/id`.
    pub fn reference(model: Model, arena: Allocator) Allocator.Error![]const u8 {
        return arena.print("{s}/{s}", .{ model.octoii.provider, model.id });
    }

    /// Whether the model reasons: whether its `supported_parameters` list `reasoning`, else where it says how it
    /// reasons; null where neither says.
    pub fn reasons(model: Model) ?bool {
        if (model.supported_parameters) |parameters| return listed(parameters, "reasoning");
        return if (model.reasoning == null) null else true;
    }

    /// Whether the model takes the request field OpenRouter names `parameter`; one that lists none takes every one.
    pub fn takes(model: Model, parameter: []const u8) bool {
        const parameters = model.supported_parameters orelse return true;
        return listed(parameters, parameter);
    }

    /// Whether the model reads `modality`.
    pub fn reads(model: Model, modality: InputModality) bool {
        return std.mem.indexOfScalar(InputModality, model.architecture.input_modalities, modality) != null;
    }

    /// Whether the model serves `kind`.
    pub fn serves(model: Model, kind: Kind) bool {
        return std.mem.indexOfScalar(Kind, model.octoii.kinds, kind) != null;
    }
};

/// Octoii's facts of a model.
pub const Facts = struct {
    /// The provider that serves it, such as "anthropic".
    provider: []const u8,
    /// The calls it serves.
    kinds: []const Kind,
    /// When its provider released it, as YYYY-MM-DD.
    release_date: ?[]const u8 = null,
    /// A text model's tools its provider runs for it.
    hosted_tools: ?[]const enum { web_search } = null,
    input_limits: ?InputLimits = null,
    /// An image model's settings, as OpenRouter's image listing describes them.
    image_parameters: ?std.json.ArrayHashMap(ParameterRange) = null,
    /// A speech model's: whether it takes instructions on how to speak.
    instructions: ?bool = null,
    /// A transcription model's: whether it tells speakers apart.
    speakers: ?bool = null,
    /// A transcription model's formats, where it does not answer in both.
    response_formats: ?[]const TranscriptionFormat = null,
    /// A decision model's: the tokens the state and any one question may take, where its provider limits them.
    question_context_length: ?u64 = null,
    /// A decision model's: whether it answers box questions.
    box: ?bool = null,
    /// A realtime transcription model's prices for its sessions, where they differ from `pricing`.
    realtime_pricing: ?Pricing = null,
    /// What sets a text model apart from its provider's others.
    features: ?Features = null,
    /// A text model's preset prompt, which a caller gives it in place of its own.
    preset_prompt: ?[]const u8 = null,
    /// Where each fact came from, by its field's path, such as "context_length" or "octoii.release_date".
    sources: ?std.json.ArrayHashMap(Source) = null,
};

/// A frame a video model takes an image of.
pub const FrameImage = enum { first_frame, last_frame };

/// A format a transcription model answers in.
pub const TranscriptionFormat = enum { json, verbose_json };

/// OpenRouter's description of the values an image model takes for one setting.
pub const ParameterRange = union(enum) {
    @"enum": struct { type: enum { @"enum" } = .@"enum", values: []const []const u8 },
    range: struct { type: enum { range } = .range, min: ?f64 = null, max: ?f64 = null },
    boolean: struct { type: enum { boolean } = .boolean },

    const variants = @import("foundation").json.Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};

/// Where a fact came from: the catalogue, the provider's listing, the person, or an assumption.
pub const Source = enum { catalogue, listing, person, assumed };

/// How a model reasons.
pub const Reasoning = struct {
    /// The efforts it takes, highest first; left out, it takes every effort.
    supported_efforts: ?[]const ReasoningEffort = null,
    default_effort: ?ReasoningEffort = null,
    /// Whether it reasons when a request does not say.
    default_enabled: ?bool = null,
    /// It always reasons, and takes no effort `none`.
    mandatory: bool,
    /// It takes a budget of reasoning tokens.
    supports_max_tokens: ?bool = null,
};

/// The largest a model's input may be.
pub const InputLimits = struct {
    request_bytes: ?u64 = null,
    image_bytes: ?u64 = null,
    image_side_pixels: ?u64 = null,
    images: ?u64 = null,
};

/// What sets a text model apart from its provider's others, each left out where no source says.
pub const Features = struct {
    /// It takes instructions updated after the first user's turn, where they stand.
    instruction_updates: ?bool = null,
    /// It takes tools added and removed where they stand.
    tool_updates: ?bool = null,
    /// It takes an effort changed where it stands, while it reasons.
    effort_updates: ?bool = null,
    /// The request's `service_tier`s it takes, such as "fast".
    service_tiers: ?[]const []const u8 = null,
    /// The `tool_choice`s it takes, a function or allowed tools as "function".
    tool_choices: ?[]const ToolChoiceKind = null,
    /// Whether each sampling field takes effect.
    sampling: ?struct {
        temperature: ?SamplingEffect = null,
        top_p: ?SamplingEffect = null,
    } = null,
};

/// A kind of `tool_choice`, a function or allowed tools being "function".
pub const ToolChoiceKind = enum { none, auto, required, function };

/// Whether a sampling field takes effect, while the model reasons and while it does not.
pub const SamplingEffect = struct {
    reasoning: ?bool = null,
    plain: ?bool = null,
};

/// A model's prices: US dollars for one unit, as a decimal string; the unit is a token unless the price says.
pub const Pricing = struct {
    prompt: []const u8,
    completion: []const u8,
    input_cache_read: ?[]const u8 = null,
    /// A token written into the prompt cache, kept for minutes.
    input_cache_write: ?[]const u8 = null,
    /// A token written into the prompt cache, kept for an hour or the model's one longer lifetime.
    input_cache_write_1h: ?[]const u8 = null,
    internal_reasoning: ?[]const u8 = null,
    audio: ?[]const u8 = null,
    audio_output: ?[]const u8 = null,
    input_audio_cache: ?[]const u8 = null,
    image: ?[]const u8 = null,
    image_token: ?[]const u8 = null,
    image_output: ?[]const u8 = null,
    web_search: ?[]const u8 = null,
    request: ?[]const u8 = null,
    /// The fraction taken off every price.
    discount: ?f64 = null,
    /// Prices that apply instead under their conditions; a later override's win.
    overrides: ?[]const PricingOverride = null,
    /// Prices of units other than a token.
    octoii: ?struct {
        /// A character of text spoken, for a model that bills by them.
        character: ?[]const u8 = null,
        /// A second of audio read or of a session, for a model that bills by them.
        second: ?[]const u8 = null,
    } = null,
};

/// A day of the week by UTC, on which a pricing override applies.
pub const UtcDay = enum { monday, tuesday, wednesday, thursday, friday, saturday, sunday };

/// Prices that replace a model's base prices for a request that meets every condition the override gives.
pub const PricingOverride = struct {
    /// For a request whose input, cached tokens among them, takes more tokens than this.
    min_prompt_tokens: ?u64 = null,
    /// Within a daily UTC window from this time, as HHMM such as 1030.
    utc_start: ?u32 = null,
    /// To before this time, as HHMM; a window may wrap past midnight.
    utc_end: ?u32 = null,
    /// On these days by UTC: the window's, or without one the whole day.
    utc_days: ?[]const UtcDay = null,
    prompt: ?[]const u8 = null,
    completion: ?[]const u8 = null,
    input_cache_read: ?[]const u8 = null,
    input_cache_write: ?[]const u8 = null,
    input_cache_write_1h: ?[]const u8 = null,
    input_audio_cache: ?[]const u8 = null,
    audio: ?[]const u8 = null,
};

/// The provider and the provider's id of the model a reference names: the provider is what stands before the first
/// `/`, so an id may hold more. Null for a reference without a provider or an id.
pub fn parseReference(text: []const u8) ?struct { provider: []const u8, id: []const u8 } {
    const slash = std.mem.indexOfScalar(u8, text, '/') orelse return null;
    if (slash == 0 or slash == text.len - 1) return null;
    return .{ .provider = text[0..slash], .id = text[slash + 1 ..] };
}

fn listed(values: []const []const u8, value: []const u8) bool {
    for (values) |each| if (std.mem.eql(u8, each, value)) return true;
    return false;
}

test "a reference is a provider and an id, which may hold slashes" {
    const parts = parseReference("openrouter/anthropic/claude-opus-5-5").?;
    try std.testing.expectEqualStrings("openrouter", parts.provider);
    try std.testing.expectEqualStrings("anthropic/claude-opus-5-5", parts.id);
    try std.testing.expectEqual(null, parseReference("/x"));
    try std.testing.expectEqual(null, parseReference("x/"));
    try std.testing.expectEqual(null, parseReference("x"));
}
