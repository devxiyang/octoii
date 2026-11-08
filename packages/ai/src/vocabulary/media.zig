//! What the media kinds and the decision kind share: Octoii's account of a usage under `octoii`, the `error` event a
//! media stream ends with, OpenRouter's data policy, and the references to files a request carries, each inline, at an
//! address or stored under its `octoii`.
const foundation = @import("foundation");
const Raw = foundation.json.Raw;
const extensions = @import("extensions.zig");
const FileExtension = extensions.FileExtension;
const Usage = @import("usage.zig").Usage;

/// A media result's `octoii`: Octoii's account of its usage, with its cost.
pub const MediaUsageExtension = struct { usage: ?Usage = null };

/// The failure a media stream ends with.
pub const MediaError = struct {
    /// The provider's code for the failure, or the failure's kind where it gives none.
    code: []const u8,
    message: []const u8,
    /// The request's field the failure is of, where the provider names one.
    param: ?[]const u8 = null,
    /// The provider's type of the failure, where it gives one.
    type: ?[]const u8 = null,
    octoii: extensions.FailureExtension,
};

/// How a media stream ends that failed, as OpenRouter's image stream sends it.
pub const MediaErrorEvent = struct {
    type: enum { @"error" } = .@"error",
    @"error": MediaError,
};

/// OpenRouter's data policy for a speech or transcription request, with each provider's own settings under `options`.
pub const DataPolicy = struct {
    /// Only endpoints that keep no data.
    zdr: ?bool = null,
    /// Whether providers that may keep and train on the request are allowed.
    data_collection: ?enum { allow, deny } = null,
    options: ?Raw = null,
};

/// An image a request refers to: at an `https` address or a data URL in `image_url.url`, or stored under `octoii`.
pub const ImageReference = struct {
    type: enum { image_url } = .image_url,
    /// An `https` address or a data URL; left out for a stored file.
    image_url: struct { url: ?[]const u8 = null },
    octoii: ?FileExtension = null,
};

/// Audio a request refers to: at an `https` address or a data URL in `audio_url.url`, or stored under `octoii`.
pub const AudioReference = struct {
    type: enum { audio_url } = .audio_url,
    audio_url: struct { url: ?[]const u8 = null },
    octoii: ?FileExtension = null,
};

/// Video a request refers to: at an `https` address or a data URL in `video_url.url`, or stored under `octoii`.
pub const VideoReference = struct {
    type: enum { video_url } = .video_url,
    video_url: struct { url: ?[]const u8 = null },
    octoii: ?FileExtension = null,
};

/// Audio given as base64 or at an address in `input_audio`, or stored under `octoii`: a sample, or a part of a
/// decision's state.
pub const AudioInput = struct {
    type: enum { input_audio } = .input_audio,
    input_audio: struct {
        /// The audio, base64, or a data URL where the provider takes one; left out for a stored file or an address.
        data: ?[]const u8 = null,
        /// An address the provider fetches.
        url: ?[]const u8 = null,
        /// Its encoding, such as `wav` or `mp3`.
        format: ?[]const u8 = null,
    },
    octoii: ?FileExtension = null,
};
