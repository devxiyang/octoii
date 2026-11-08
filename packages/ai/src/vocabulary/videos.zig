//! The video kind: OpenRouter's video API, its request and its job, with Octoii's account of the job and its failure
//! under `octoii`. A job is plain data, which a caller keeps and retrieves again.
const foundation = @import("foundation");
const Raw = foundation.json.Raw;
const Variants = foundation.json.Variants;
const media = @import("media.zig");
const extensions = @import("extensions.zig");
const Usage = @import("usage.zig").Usage;

/// An image a video starts or ends with.
pub const FrameImage = struct {
    type: enum { image_url } = .image_url,
    image_url: struct { url: ?[]const u8 = null },
    octoii: ?extensions.FileExtension = null,
    frame_type: enum { first_frame, last_frame },
};

/// An image, audio or video a video follows, without pinning a frame.
pub const InputReference = union(enum) {
    image: media.ImageReference,
    audio: media.AudioReference,
    video: media.VideoReference,

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};

/// A request for a video, which a provider makes as a job.
pub const VideoRequest = struct {
    /// The model's reference.
    model: []const u8,
    /// Left out only for a model that makes a video from images alone.
    prompt: ?[]const u8 = null,
    /// Seconds.
    duration: ?u32 = null,
    /// Such as "720p" or "1080p".
    resolution: ?[]const u8 = null,
    /// Such as "16:9".
    aspect_ratio: ?[]const u8 = null,
    /// "WIDTHxHEIGHT", in place of `resolution` and `aspect_ratio`.
    size: ?[]const u8 = null,
    frame_images: ?[]const FrameImage = null,
    /// Images, audio or video to follow, without pinning a frame.
    input_references: ?[]const InputReference = null,
    generate_audio: ?bool = null,
    seed: ?i64 = null,
    /// A completed job to edit or extend, on the model that made it.
    previous_job_id: ?[]const u8 = null,
    /// An upscaling model's.
    creativity: ?f64 = null,
    /// An upscaling model's.
    upscale_factor: ?f64 = null,
    /// An https address told when the job ends.
    callback_url: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    trace: ?Raw = null,
    user: ?[]const u8 = null,
    /// Its provider's own options alone; a provider refuses any other preference.
    provider: ?@import("provider.zig").ProviderPreferences = null,
};

/// How a video job stands: on its way, or ended for good.
pub const VideoJobStatus = enum {
    pending,
    in_progress,
    completed,
    failed,
    cancelled,
    expired,

    /// Whether a job of this status has ended for good.
    pub fn ended(status: VideoJobStatus) bool {
        return status != .pending and status != .in_progress;
    }
};

/// A video job's `octoii`: the model making it, Octoii's account of it, and a failed job's failure, classified.
pub const VideoJobExtension = struct {
    /// The reference of the model making it.
    model: []const u8,
    /// Its seconds and its cost.
    usage: ?Usage = null,
    failure: ?extensions.FailureExtension = null,
};

/// A video job: how it stands, its outputs once it completes, and Octoii's account of it.
pub const VideoJob = struct {
    id: []const u8,
    status: VideoJobStatus,
    polling_url: ?[]const u8 = null,
    generation_id: ?[]const u8 = null,
    /// The outputs' addresses, which take the provider's credentials.
    unsigned_urls: ?[]const []const u8 = null,
    /// Signed addresses of the outputs, which take none until `expires_at`: secrets.
    urls: ?[]const []const u8 = null,
    /// In Unix seconds, when the provider stops keeping the outputs, where it says.
    expires_at: ?i64 = null,
    usage: ?struct { cost: ?f64 = null, is_byok: ?bool = null } = null,
    /// Why the job failed, was cancelled or expired.
    @"error": ?[]const u8 = null,
    octoii: VideoJobExtension,
};

/// One of a completed job's outputs: what it is, and its bytes.
pub const VideoContent = struct { media_type: []const u8, data: []const u8 };
