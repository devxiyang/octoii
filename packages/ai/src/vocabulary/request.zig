//! A text request: the Responses API's request as OpenRouter defines it, but for what the vocabulary leaves out — state
//! at a provider, hosted tools other than web search and tool search, and `stream` — which has no field here.
const foundation = @import("foundation");
const Raw = foundation.json.Raw;
const Variants = foundation.json.Variants;
const content = @import("content.zig");
const items = @import("items.zig");
const tools = @import("tools.zig");
const Plugin = @import("plugins.zig").Plugin;
const ProviderPreferences = @import("provider.zig").ProviderPreferences;

/// How a text model reasons: its effort or budget, its summary, and the reasoning it reads.
pub const ReasoningConfig = struct {
    effort: ?items.ReasoningEffort = null,
    summary: ?enum { auto, concise, detailed } = null,
    /// The reasoning of earlier turns the model reads: `all_turns`, `current_turn`, or as the model does by default
    /// (`auto`).
    context: ?enum { auto, all_turns, current_turn } = null,
    /// `pro` reasons more deeply, on the models that can; `standard` by default.
    mode: ?enum { standard, pro } = null,
    /// `false` is the effort `none`.
    enabled: ?bool = null,
    /// A budget of reasoning tokens instead of an effort, for a model whose facts say it takes one.
    max_tokens: ?u64 = null,
};

/// An answer in JSON of a schema, as far as the provider holds an answer to it.
pub const JsonSchemaFormat = struct {
    type: enum { json_schema } = .json_schema,
    name: []const u8,
    description: ?[]const u8 = null,
    /// The JSON Schema of the answer.
    schema: Raw,
    strict: ?bool = null,
};

/// The form of an answer's text: free text, any JSON object, or JSON of a schema.
pub const TextFormat = union(enum) {
    text: struct { type: enum { text } = .text },
    json_object: struct { type: enum { json_object } = .json_object },
    json_schema: JsonSchemaFormat,

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};

/// The form of an answer's text and how much of it the model writes.
pub const TextConfig = struct {
    format: ?TextFormat = null,
    verbosity: ?enum { low, medium, high, xhigh, max } = null,
};

/// Automatic prompt caching, with its lifetime: Anthropic's and OpenRouter's.
pub const CacheControl = struct {
    type: enum { ephemeral } = .ephemeral,
    ttl: ?enum { @"5m", @"1h" } = null,
};

/// Explicit prompt caching: only at the breakpoints, with OpenAI's lifetime of what they keep.
pub const PromptCacheOptions = struct {
    mode: enum { explicit } = .explicit,
    ttl: ?content.PromptCacheTtl = null,
};

/// How a search for deferred tools ranks them: by BM25, by a regular expression, or by a tool of the caller's.
pub const DeferredToolsSearch = union(enum) {
    bm25: struct {
        type: enum { bm25 } = .bm25,
        max_results: ?u32 = null,
    },
    regex: struct {
        type: enum { regex } = .regex,
        max_results: ?u32 = null,
    },
    custom: struct {
        type: enum { custom } = .custom,
        /// The caller's tool that searches.
        tool_id: []const u8,
        /// The field of that tool's output that holds what it found.
        result_key: []const u8,
        max_results: ?u32 = null,
    },

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};

/// How deferred tools are searched, by OpenRouter's protocol for them.
pub const DeferredTools = struct {
    protocol: enum { v1 } = .v1,
    profile: enum { portable } = .portable,
    validation: enum { runtime } = .runtime,
    search: DeferredToolsSearch,
};

/// A condition that stops the steps of OpenRouter's hosted tools: any one that holds stops them.
pub const StopServerToolsCondition = union(enum) {
    step_count_is: struct {
        type: enum { step_count_is } = .step_count_is,
        step_count: u32,
    },
    has_tool_call: struct {
        type: enum { has_tool_call } = .has_tool_call,
        tool_name: []const u8,
    },
    finish_reason_is: struct {
        type: enum { finish_reason_is } = .finish_reason_is,
        reason: []const u8,
    },
    max_cost: struct {
        type: enum { max_cost } = .max_cost,
        max_cost_in_dollars: f64,
    },
    max_tokens_used: struct {
        type: enum { max_tokens_used } = .max_tokens_used,
        max_tokens: u64,
    },

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};

/// What OpenRouter tells the caller's observability of a request.
pub const TraceConfig = struct {
    trace_id: ?[]const u8 = null,
    trace_name: ?[]const u8 = null,
    span_name: ?[]const u8 = null,
    generation_name: ?[]const u8 = null,
    parent_span_id: ?[]const u8 = null,
};

/// What OpenRouter reports of how it handled a streamed request, in `response.debug` events.
pub const DebugOptions = struct {
    /// Report the request body OpenRouter sent the provider.
    echo_upstream_body: ?bool = null,
};

/// What a response includes beyond its default: the addresses of input images, and reasoning as its provider keeps it.
pub const ResponseIncludable = enum { @"message.input_image.image_url", @"reasoning.encrypted_content" };

/// How fast and at what price a provider serves the request; `fast` is `priority`.
pub const ServiceTier = enum { auto, default, fast, flex, priority, scale, ultrafast };

/// A text request: everything the model reads, the tools it may use, and the settings it answers by.
pub const ResponsesRequest = struct {
    /// The model's reference, such as `anthropic/claude-opus-5-5`.
    model: []const u8,
    /// The system prompt at the start.
    instructions: ?[]const u8 = null,
    /// The conversation: text, as one user message, or items.
    input: ?content.TextOr(items.Item) = null,
    tools: ?[]const tools.Tool = null,
    tool_choice: ?tools.ToolChoice = null,
    parallel_tool_calls: ?bool = null,
    /// The most steps of OpenRouter's hosted tools a request takes.
    max_tool_calls: ?u32 = null,
    reasoning: ?ReasoningConfig = null,
    text: ?TextConfig = null,
    max_output_tokens: ?u64 = null,
    /// What the response may hold, for the models that make images.
    modalities: ?[]const enum { text, image } = null,
    /// The image settings of the provider's own, such as `aspect_ratio`: an object.
    image_config: ?Raw = null,
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    top_k: ?f64 = null,
    frequency_penalty: ?f64 = null,
    presence_penalty: ?f64 = null,
    /// Up to 4 sequences the answer stops at.
    stop: ?content.TextOr([]const u8) = null,
    top_logprobs: ?u32 = null,
    truncation: ?enum { auto, disabled } = null,
    include: ?[]const ResponseIncludable = null,
    /// Names the conversation, by which a provider sends its requests to the same cache.
    prompt_cache_key: ?[]const u8 = null,
    prompt_cache_options: ?PromptCacheOptions = null,
    cache_control: ?CacheControl = null,
    /// Names the conversation, by which OpenRouter sends its requests to the same provider.
    session_id: ?[]const u8 = null,
    deferred_tools: ?DeferredTools = null,
    stop_server_tools_when: ?[]const StopServerToolsCondition = null,
    provider: ?ProviderPreferences = null,
    /// Models OpenRouter falls back to, in order.
    models: ?[]const []const u8 = null,
    plugins: ?[]const Plugin = null,
    service_tier: ?ServiceTier = null,
    /// Up to 16 pairs of text kept with the request in the provider's records: an object.
    metadata: ?Raw = null,
    /// A stable id of the person, by which a provider tells its users apart in abuse.
    safety_identifier: ?[]const u8 = null,
    user: ?[]const u8 = null,
    trace: ?TraceConfig = null,
    debug: ?DebugOptions = null,
    /// Nothing is kept at the provider: `false` is the only value a request is sent with.
    store: ?bool = null,
};
