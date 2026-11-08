//! Anthropic's Messages API on the wire, as Zig types: the request ai sends, its content blocks and tools, and the
//! events, usage and errors its stream sends back. A request is encoded canonically like everything ai writes; a block
//! the model wrote goes back as it came, kept as raw JSON.
const std = @import("std");
const foundation = @import("foundation");
const Raw = foundation.json.Raw;
const Variants = foundation.json.Variants;
const vocabulary = @import("vocabulary");

/// The version of Anthropic's API ai speaks.
pub const api_version = "2026-10-21";
/// The beta that defines a tool in a system message, and takes one away.
pub const inline_tools_beta = "inline-tools-2026-09-15";
/// The beta that changes the effort in a system message.
pub const message_effort_beta = "mid-conversation-output-config-2026-07-01";
/// The beta of fast mode, which the models that no longer need it still take.
pub const fast_mode_beta = "fast-mode-2026-02-01";
/// The name of Anthropic's basic web search, which its calls carry.
pub const web_search_name = "web_search";
/// The names of Anthropic's tool searches, which their calls carry.
pub const tool_search_names = [_][]const u8{ "tool_search_tool_bm25", "tool_search_tool_regex" };
/// The cache marks Anthropic takes in a request, its automatic one among them.
pub const cache_marks = 4;

pub const Request = struct {
    model: []const u8,
    max_tokens: u64,
    system: ?[]const Block = null,
    messages: []const Message,
    tools: ?[]const Tool = null,
    tool_choice: ?ToolChoice = null,
    thinking: ?Thinking = null,
    output_config: ?OutputConfig = null,
    stop_sequences: ?[]const []const u8 = null,
    metadata: ?struct { user_id: []const u8 } = null,
    cache_control: ?vocabulary.request.CacheControl = null,
    service_tier: ?enum { auto, standard_only } = null,
    speed: ?enum { fast } = null,
    stream: bool = true,
};

pub const Message = struct {
    role: enum { user, assistant, system },
    content: []const Block,
    /// A system message's change of the effort from where it stands.
    output_config: ?OutputConfig = null,
};

pub const OutputConfig = struct {
    effort: ?vocabulary.items.ReasoningEffort = null,
    format: ?struct { type: enum { json_schema } = .json_schema, schema: Raw } = null,
};

pub const Thinking = struct {
    type: enum { disabled, enabled, adaptive },
    budget_tokens: ?u64 = null,
    display: ?enum { summarized } = null,
};

pub const ToolChoice = struct {
    type: enum { auto, none, any, tool },
    name: ?[]const u8 = null,
    disable_parallel_tool_use: ?bool = null,
};

/// A cache mark on a block: what ends there is kept, for the request's lifetime or Anthropic's default.
pub const CacheControl = vocabulary.request.CacheControl;

/// A content block of a message, or of the system prompt.
pub const Block = union(enum) {
    text: struct { type: enum { text } = .text, text: []const u8, cache_control: ?CacheControl = null },
    image: struct { type: enum { image } = .image, source: Source },
    document: struct { type: enum { document } = .document, source: Source, title: ?[]const u8 = null },
    tool_use: struct { type: enum { tool_use } = .tool_use, id: []const u8, name: []const u8, input: Raw },
    tool_result: struct {
        type: enum { tool_result } = .tool_result,
        tool_use_id: []const u8,
        content: vocabulary.TextOr(Block),
        is_error: ?bool = null,
    },
    thinking: struct { type: enum { thinking } = .thinking, thinking: []const u8, signature: []const u8 },
    redacted_thinking: struct { type: enum { redacted_thinking } = .redacted_thinking, data: []const u8 },
    tool_addition: struct {
        type: enum { tool_addition } = .tool_addition,
        tool: struct { type: enum { tool_definition } = .tool_definition, definition: Tool },
    },
    tool_removal: struct {
        type: enum { tool_removal } = .tool_removal,
        tool: struct { type: enum { tool_reference } = .tool_reference, name: []const u8 },
    },
    /// A block the model wrote, going back as it came.
    raw: Raw,

    pub fn jsonStringify(block: Block, writer: *std.json.Stringify) std.json.Stringify.Error!void {
        switch (block) {
            inline else => |payload| try writer.write(payload),
        }
    }
};

pub const Source = union(enum) {
    base64: struct { type: enum { base64 } = .base64, media_type: []const u8, data: []const u8 },
    url: struct { type: enum { url } = .url, url: []const u8 },
    text: struct { type: enum { text } = .text, media_type: []const u8 = "text/plain", data: []const u8 },

    pub fn jsonStringify(source: Source, writer: *std.json.Stringify) std.json.Stringify.Error!void {
        switch (source) {
            inline else => |payload| try writer.write(payload),
        }
    }
};

pub const Tool = union(enum) {
    function: struct {
        name: []const u8,
        description: ?[]const u8 = null,
        input_schema: Raw,
        strict: ?bool = null,
        defer_loading: ?bool = null,
    },
    web_search: struct {
        type: enum { web_search_20250305 } = .web_search_20250305,
        name: []const u8 = web_search_name,
        max_uses: ?u32 = null,
        allowed_domains: ?[]const []const u8 = null,
        blocked_domains: ?[]const []const u8 = null,
        user_location: ?struct {
            type: enum { approximate } = .approximate,
            city: ?[]const u8 = null,
            region: ?[]const u8 = null,
            country: ?[]const u8 = null,
            timezone: ?[]const u8 = null,
        } = null,
    },
    tool_search: struct {
        type: enum { tool_search_tool_bm25_20251119, tool_search_tool_regex_20251119 },
        name: []const u8,
    },

    pub fn jsonStringify(tool: Tool, writer: *std.json.Stringify) std.json.Stringify.Error!void {
        switch (tool) {
            inline else => |payload| try writer.write(payload),
        }
    }
};

// --- The stream --------------------------------------------------------------------------------------------------

/// What a request used, as Anthropic counts it: its input apart from what it read from the cache and wrote to it.
/// `message_delta` gives the counts that changed.
pub const Usage = struct {
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    cache_creation_input_tokens: ?u64 = null,
    cache_read_input_tokens: ?u64 = null,
    cache_creation: ?struct { ephemeral_5m_input_tokens: ?u64 = null, ephemeral_1h_input_tokens: ?u64 = null } = null,
    server_tool_use: ?struct { web_search_requests: ?u64 = null } = null,
};

/// An error as Anthropic reports it: its type, such as `overloaded_error`, and its message.
pub const Error = struct { type: []const u8, message: []const u8 };

/// The event types Anthropic documents, which must read as they say; another, added later, is passed over.
pub const known_events = [_][]const u8{ "message_start", "content_block_start", "content_block_delta", "content_block_stop", "message_delta", "message_stop", "ping", "error" };

pub const Event = union(enum) {
    message_start: struct { type: enum { message_start }, message: struct { id: []const u8, usage: ?Usage = null } },
    /// The block as it begins, kept as JSON: it goes back to the model as it came.
    content_block_start: struct { type: enum { content_block_start }, index: u32, content_block: std.json.Value },
    content_block_delta: struct { type: enum { content_block_delta }, index: u32, delta: Delta },
    content_block_stop: struct { type: enum { content_block_stop }, index: u32 },
    message_delta: struct { type: enum { message_delta }, delta: struct { stop_reason: ?[]const u8 = null }, usage: ?Usage = null },
    message_stop: struct { type: enum { message_stop } },
    ping: struct { type: enum { ping } },
    @"error": struct { type: enum { @"error" }, @"error": Error },

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};

/// A change in a block as it streams.
pub const Delta = union(enum) {
    text_delta: struct { type: enum { text_delta }, text: []const u8 },
    input_json_delta: struct { type: enum { input_json_delta }, partial_json: []const u8 },
    thinking_delta: struct { type: enum { thinking_delta }, thinking: []const u8 },
    signature_delta: struct { type: enum { signature_delta }, signature: []const u8 },
    citations_delta: struct { type: enum { citations_delta }, citation: std.json.Value },

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};
