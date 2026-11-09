//! Octoii's extensions to the protocol: the objects under an `octoii` key. Each is defined once here and used wherever
//! the vocabulary carries it; a reader that does not know them passes over them, and none reaches a provider.
const foundation = @import("foundation");
const Raw = foundation.json.Raw;

/// What kind of failure ended a request, which decides whether trying again may help.
pub const FailureKind = enum {
    context_overflow,
    payload_too_large,
    rate_limit,
    quota,
    auth,
    forbidden,
    content_filter,
    invalid_request,
    server,
    transport,
    invalid_response,
    timeout,
    aborted,
};

/// An error's `octoii`: the failure's kind, whether it is retryable, how long to wait and the HTTP status; and, for a
/// quota used up, when it is given again and over what window it is counted.
pub const FailureExtension = struct {
    kind: FailureKind,
    retryable: bool,
    /// How long to wait before trying again, where the provider says.
    retry_after_ms: ?u64 = null,
    /// The HTTP status the provider answered with.
    status: ?u16 = null,
    /// When a quota used up is given again, in milliseconds since the epoch, where the provider says.
    reset_at_ms: ?i64 = null,
    /// How long the window a quota is counted over lasts, in minutes — 300 for five hours, 10080 for a week — where
    /// the provider says.
    window_minutes: ?u32 = null,
};

/// A file's `octoii`: a stored file, what a file is where no data URL says, and its name where its content has no
/// field for one.
pub const FileExtension = struct {
    /// A stored file, whose bytes the host's `Files` gives when the request is sent; where it is the file's one
    /// source, the content has no other.
    ref: ?[]const u8 = null,
    /// What the file is, where no data URL says; it is believed before the file's bytes and name.
    media_type: ?[]const u8 = null,
    /// The file's name, where its content has no field for one.
    filename: ?[]const u8 = null,
};

/// Whether a file's `octoii` names a stored file.
pub fn stored(extension: ?FileExtension) bool {
    const given = extension orelse return false;
    return given.ref != null;
}

/// The `octoii` of an item a model wrote: which model wrote it, and what its provider attached.
pub const ItemExtension = struct {
    /// The reference of the model that wrote the item.
    model: ?[]const u8 = null,
    /// What the provider attached that no protocol has a field for, such as a signature on a function call: an object
    /// of objects, each under its provider's id.
    provider_metadata: ?Raw = null,
};

/// A `function_call_output`'s `octoii`: whether the call failed, as its output says.
pub const FunctionCallOutputExtension = struct {
    is_error: ?bool = null,
};

/// A response's `octoii`: the model that answered, and the tokens the context of its last request took.
pub const ResponseExtension = struct {
    /// The reference of the model that answered.
    model: ?[]const u8 = null,
    /// The input tokens of the response's last request alone, even where the response was continued.
    context_tokens: ?u64 = null,
};

/// Usage's `octoii`: the counts a provider gives apart that the protocol's usage has no field for.
pub const UsageExtension = struct {
    /// Of `cache_write_tokens`, those kept for an hour or longer.
    cache_write_long_tokens: ?u64 = null,
    /// Of `cached_tokens`, audio its provider prices apart.
    cache_read_audio_tokens: ?u64 = null,
    /// Of `input_tokens`, audio its provider prices apart.
    input_audio_tokens: ?u64 = null,
    /// Of `input_tokens`, images its provider prices apart.
    input_image_tokens: ?u64 = null,
    /// Of `output_tokens`, images its provider prices apart.
    output_image_tokens: ?u64 = null,
};
