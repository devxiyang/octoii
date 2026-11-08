//! What a text request returns: the response's status, its output items, its usage and its error, with OpenRouter's
//! reports of how it routed the request and Octoii's extensions.
const foundation = @import("foundation");
const Raw = foundation.json.Raw;
const extensions = @import("extensions.zig");
const OutputItem = @import("items.zig").OutputItem;

/// Where a response stands: under way, or ended `completed`, `incomplete` or `failed` — or `cancelled`, stopped by its
/// caller before it ended, keeping what had come.
pub const ResponseStatus = enum { in_progress, completed, incomplete, failed, cancelled };

/// Why a response ended `incomplete`: at its output limit, filtered by the provider's policy, or — Octoii's — cut off
/// by its caller, as a stream its caller cancelled ends: an answer cut short, with what came of it.
pub const IncompleteDetails = struct {
    reason: ?enum { max_output_tokens, content_filter, cancelled } = null,
};

/// What a request used, in tokens and US dollars, as the provider reports it.
pub const ResponseUsage = struct {
    input_tokens: u64,
    input_tokens_details: struct {
        /// Of `input_tokens`, those read from the prompt cache.
        cached_tokens: u64,
        /// Of `input_tokens`, those written into the prompt cache.
        cache_write_tokens: ?u64 = null,
    },
    output_tokens: u64,
    output_tokens_details: struct {
        /// Of `output_tokens`, those spent reasoning.
        reasoning_tokens: u64,
    },
    total_tokens: u64,
    /// What the request cost in US dollars, where the provider says.
    cost: ?f64 = null,
    cost_details: ?struct {
        upstream_inference_cost: ?f64 = null,
        upstream_inference_input_cost: f64,
        upstream_inference_output_cost: f64,
        server_tool_cost: ?f64 = null,
    } = null,
    /// Whether the request was billed to the caller's own key at the provider.
    is_byok: ?bool = null,
    server_tool_use_details: ?struct {
        web_search_requests: ?u64 = null,
        tool_calls_requested: ?u64 = null,
        tool_calls_executed: ?u64 = null,
    } = null,
    octoii: ?extensions.UsageExtension = null,
};

/// Why a response failed: the provider's code, or the failure's kind where it gives none, and the failure under
/// `octoii`.
pub const ResponseError = struct {
    /// The provider's code for the failure, or the failure's kind where it gives none.
    code: []const u8,
    message: []const u8,
    /// What OpenRouter adds, such as the checks of its alignment plugin: an object.
    metadata: ?Raw = null,
    octoii: extensions.FailureExtension,
};

/// OpenRouter's kind of error, the same in every API it serves.
pub const ErrorType = enum {
    context_length_exceeded,
    max_tokens_exceeded,
    token_limit_exceeded,
    string_too_long,
    authentication,
    permission_denied,
    payment_required,
    rate_limit_exceeded,
    provider_overloaded,
    provider_unavailable,
    invalid_request,
    invalid_prompt,
    not_found,
    precondition_failed,
    payload_too_large,
    unprocessable,
    content_policy_violation,
    refusal,
    invalid_image,
    image_too_large,
    image_too_small,
    unsupported_image_format,
    image_not_found,
    image_download_failed,
    server,
    timeout,
    unmapped,
};

/// How OpenRouter routed a request: the model asked for, the endpoints it had and the attempts it made.
pub const OpenRouterMetadata = struct {
    /// The model the request asked for.
    requested: []const u8,
    /// How OpenRouter chose the model, such as `direct` or `fallback`.
    strategy: []const u8,
    /// In words, what OpenRouter did.
    summary: []const u8,
    /// The attempt that answered, counted from 1.
    attempt: u32,
    attempts: ?[]const struct { model: []const u8, provider: []const u8, status: u16 } = null,
    endpoints: struct { total: u32, available: []const Raw },
    is_byok: bool,
    region: ?[]const u8 = null,
    /// In milliseconds.
    generation_time: ?u64 = null,
    params: ?Raw = null,
    pipeline: ?[]const Raw = null,
};

/// What OpenRouter's armor found of the function calls of a response.
pub const SafeguardResult = struct {
    type: enum { dangerous_tool_use } = .dangerous_tool_use,
    /// Each call's evaluation, under `tool_uses` by call: an object.
    status: Raw,
};

/// The checks OpenRouter's alignment plugin made of a response.
pub const Alignment = struct {
    calls: []const Raw,
};

/// What a text request returns: its status, its output items, its usage and, for a failed one, its error.
pub const Response = struct {
    id: []const u8,
    status: ResponseStatus,
    incomplete_details: ?IncompleteDetails = null,
    output: []const OutputItem,
    usage: ?ResponseUsage = null,
    @"error": ?ResponseError = null,
    error_type: ?ErrorType = null,
    openrouter_metadata: ?OpenRouterMetadata = null,
    safeguard_results: ?[]const SafeguardResult = null,
    alignment: ?Alignment = null,
    octoii: ?extensions.ResponseExtension = null,
};
