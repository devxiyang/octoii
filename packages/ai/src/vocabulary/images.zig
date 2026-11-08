//! The image kind: OpenRouter's image API, its request, its response and the events of its stream, with Octoii's
//! account of the usage under `octoii`.
const foundation = @import("foundation");
const Raw = foundation.json.Raw;
const Variants = foundation.json.Variants;
const media = @import("media.zig");
const ProviderPreferences = @import("provider.zig").ProviderPreferences;

/// A request for images: a prompt, references to edit or follow, and the settings of the images made.
pub const ImageRequest = struct {
    /// The model's reference.
    model: []const u8,
    prompt: []const u8,
    /// How many images to make, at most.
    n: ?u32 = null,
    /// A resolution tier, such as "1K" or "4K".
    resolution: ?[]const u8 = null,
    /// Such as "16:9", or "auto".
    aspect_ratio: ?[]const u8 = null,
    /// A resolution tier, which stands for `resolution` beside `aspect_ratio`, or "WIDTHxHEIGHT", in place of both.
    size: ?[]const u8 = null,
    quality: ?enum { auto, low, medium, high, xhigh, max } = null,
    output_format: ?enum { png, jpeg, webp, svg } = null,
    background: ?enum { auto, transparent, @"opaque" } = null,
    /// 0 to 100, for webp and jpeg.
    output_compression: ?u32 = null,
    seed: ?i64 = null,
    /// Images to edit, or to follow in style or subject.
    input_references: ?[]const media.ImageReference = null,
    session_id: ?[]const u8 = null,
    trace: ?Raw = null,
    user: ?[]const u8 = null,
    provider: ?ProviderPreferences = null,
};

/// What making images used, as the image API reports it.
pub const ImageUsage = struct {
    /// Images and text read.
    prompt_tokens: u64,
    completion_tokens: u64,
    total_tokens: u64,
    prompt_tokens_details: ?struct { cached_tokens: ?u64 = null, cache_write_tokens: ?u64 = null } = null,
    completion_tokens_details: ?struct { image_tokens: ?u64 = null, reasoning_tokens: ?u64 = null } = null,
    cost: ?f64 = null,
    is_byok: ?bool = null,
};

/// An image made: its bytes, base64, and what it is, where the provider says.
pub const ImageData = struct { b64_json: []const u8, media_type: ?[]const u8 = null };

/// The images a request made, and what it used.
pub const ImageResponse = struct {
    /// When the images were made, in Unix seconds.
    created: i64,
    data: []const ImageData,
    usage: ?ImageUsage = null,
    octoii: ?media.MediaUsageExtension = null,
};

/// A preview of an image still being made.
pub const ImagePartialImageEvent = struct {
    type: enum { @"image_generation.partial_image" } = .@"image_generation.partial_image",
    partial_image_index: u32,
    b64_json: []const u8,
};

/// Text of an image made as text, such as SVG, as it is written.
pub const ImageTextChunkEvent = struct {
    type: enum { @"image_generation.text_chunk" } = .@"image_generation.text_chunk",
    text: []const u8,
    /// `content` is the image; `reasoning` and `draft` are the provider's steps towards it.
    phase: enum { content, reasoning, draft },
};

/// An image made, with the usage of what made it where its provider reports one, and Octoii's account of it.
pub const ImageCompletedEvent = struct {
    type: enum { @"image_generation.completed" } = .@"image_generation.completed",
    b64_json: []const u8,
    media_type: ?[]const u8 = null,
    created: i64,
    usage: ?ImageUsage = null,
    octoii: ?media.MediaUsageExtension = null,
};

/// An event of an image stream: previews, text, each image made, or the failure that ends it.
pub const ImageStreamEvent = union(enum) {
    partial_image: ImagePartialImageEvent,
    text_chunk: ImageTextChunkEvent,
    completed: ImageCompletedEvent,
    @"error": media.MediaErrorEvent,

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};
