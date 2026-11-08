//! The units of a conversation: messages, function and custom tool calls with their outputs, reasoning, web and tool
//! searches, changes to the tools and the effort from where they stand, compactions, and OpenRouter's blocked calls.
//! Every item a response's output may hold carries Octoii's item extension under `octoii`.
const std = @import("std");
const foundation = @import("foundation");
const Raw = foundation.json.Raw;
const Variants = foundation.json.Variants;
const content = @import("content.zig");
const TextOr = content.TextOr;
const extensions = @import("extensions.zig");
const ItemExtension = extensions.ItemExtension;
const Tool = @import("tools.zig").Tool;

/// Where a call or a message stands: still being written, written whole, or cut off.
pub const ItemStatus = enum { in_progress, completed, incomplete };

/// Where a hosted tool's call stands, which may also have failed.
pub const HostedToolStatus = enum { in_progress, completed, incomplete, failed };

/// A message of the user, or a developer or system message, which updates the instructions from where it stands.
pub const InputMessage = struct {
    type: ?enum { message } = null,
    id: ?[]const u8 = null,
    role: enum { user, developer, system },
    content: TextOr(content.InputContent),
};

/// An assistant message: what a model answered, or an answer the caller gives as a model's.
pub const OutputMessage = struct {
    type: ?enum { message } = null,
    id: ?[]const u8 = null,
    role: enum { assistant } = .assistant,
    content: TextOr(content.OutputContent),
    /// `commentary` for a message on the way, `final_answer` for the answer; models that write both need it back.
    phase: ?enum { commentary, final_answer } = null,
    status: ?ItemStatus = null,
    octoii: ?ItemExtension = null,
};

/// An item in which the model asks for a function by name, with its arguments as JSON text.
pub const FunctionCall = struct {
    type: enum { function_call } = .function_call,
    /// The item's id: its provider's, carried as it came, as every id a provider gives is its data.
    id: ?[]const u8 = null,
    /// The call's id, which its output carries: its provider's, or one ai minted where the provider left it empty or
    /// gave it to another call. A caller that names the call by an id of its own, as Siphon names a call's record,
    /// keeps this one beside it: the conversation goes by this one, and a provider takes back only ids of its own.
    call_id: []const u8,
    name: []const u8,
    /// The namespace of the function, for a function within one.
    namespace: ?[]const u8 = null,
    arguments: []const u8,
    /// The function is `async`: its output may come in a later request.
    async: ?bool = null,
    /// `incomplete` for a call cut off, whose arguments may be cut and which is never run.
    status: ?ItemStatus = null,
    octoii: ?ItemExtension = null,
};

/// An item that gives a function call's output back to the model.
pub const FunctionCallOutput = struct {
    type: enum { function_call_output } = .function_call_output,
    id: ?[]const u8 = null,
    call_id: []const u8,
    output: TextOr(content.InputContent),
    status: ?ItemStatus = null,
    octoii: ?extensions.FunctionCallOutputExtension = null,
};

/// An item in which the model calls a custom tool with text.
pub const CustomToolCall = struct {
    type: enum { custom_tool_call } = .custom_tool_call,
    id: ?[]const u8 = null,
    call_id: []const u8,
    name: []const u8,
    namespace: ?[]const u8 = null,
    input: []const u8,
    async: ?bool = null,
    status: ?ItemStatus = null,
    octoii: ?ItemExtension = null,
};

/// An item that gives a custom tool call's output back to the model.
pub const CustomToolCallOutput = struct {
    type: enum { custom_tool_call_output } = .custom_tool_call_output,
    id: ?[]const u8 = null,
    call_id: []const u8,
    output: TextOr(content.InputContent),
};

/// Whose reasoning a reasoning item holds, which decides the models it goes back to.
pub const ReasoningFormat = enum {
    unknown,
    @"openai-responses-v1",
    @"azure-openai-responses-v1",
    @"bedrock-openai-responses-v1",
    @"bedrock-xai-responses-v1",
    @"xai-responses-v1",
    @"meta-responses-v1",
    @"anthropic-claude-v1",
    @"google-gemini-v1",
};

/// What a model thought before it answered, as far as its provider shows it, with what it needs to go on from it.
pub const ReasoningItem = struct {
    type: enum { reasoning } = .reasoning,
    id: []const u8,
    /// The summary of the reasoning, left out where its provider shows none.
    summary: ?[]const content.SummaryText = null,
    content: ?[]const content.ReasoningText = null,
    /// The reasoning as its provider keeps it, which only the model that wrote it reads.
    encrypted_content: ?[]const u8 = null,
    /// What the provider signed the reasoning with, which only the model that wrote it checks.
    signature: ?[]const u8 = null,
    format: ?ReasoningFormat = null,
    status: ?ItemStatus = null,
    octoii: ?ItemExtension = null,
};

/// A web page a search found.
pub const WebSearchSource = struct {
    type: enum { url } = .url,
    url: []const u8,
};

/// What a web search did: searched, opened a page, or looked for a pattern in one.
pub const WebSearchAction = union(enum) {
    search: struct {
        type: enum { search } = .search,
        query: []const u8,
        queries: ?[]const []const u8 = null,
        sources: ?[]const WebSearchSource = null,
    },
    open_page: struct {
        type: enum { open_page } = .open_page,
        url: ?[]const u8 = null,
    },
    find_in_page: struct {
        type: enum { find_in_page } = .find_in_page,
        url: []const u8,
        pattern: []const u8,
    },

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};

/// A web search the provider ran, as the Responses API reports it.
pub const WebSearchCall = struct {
    type: enum { web_search_call } = .web_search_call,
    id: []const u8,
    status: enum { in_progress, searching, completed, failed },
    action: ?WebSearchAction = null,
    octoii: ?ItemExtension = null,
};

/// A web search OpenRouter ran.
pub const OpenRouterWebSearchCall = struct {
    type: enum { @"openrouter:web_search" } = .@"openrouter:web_search",
    id: ?[]const u8 = null,
    status: HostedToolStatus,
    action: ?struct {
        type: enum { search } = .search,
        query: []const u8,
        sources: ?[]const WebSearchSource = null,
    } = null,
    @"error": ?[]const u8 = null,
    octoii: ?ItemExtension = null,
};

/// Who runs a search for deferred tools: the provider (`server`), or the caller (`client`), who answers it.
pub const ToolSearchExecution = enum { server, client };

/// A search for deferred tools.
pub const ToolSearchCall = struct {
    type: enum { tool_search_call } = .tool_search_call,
    id: ?[]const u8 = null,
    call_id: []const u8,
    execution: ToolSearchExecution,
    arguments: ?Raw = null,
    status: ?ItemStatus = null,
    octoii: ?ItemExtension = null,
};

/// The tools a search for deferred tools found, which the model may use from where they stand.
pub const ToolSearchOutput = struct {
    type: enum { tool_search_output } = .tool_search_output,
    id: ?[]const u8 = null,
    call_id: []const u8,
    execution: ToolSearchExecution,
    tools: []const Tool,
    status: ?ItemStatus = null,
    octoii: ?ItemExtension = null,
};

/// A search for deferred tools that OpenRouter ran, with the tools it found.
pub const OpenRouterToolSearchCall = struct {
    type: enum { @"openrouter:tool_search" } = .@"openrouter:tool_search",
    id: ?[]const u8 = null,
    status: HostedToolStatus,
    query: ?[]const u8 = null,
    matches: ?[]const struct {
        tool_id: []const u8,
        /// The tool found, as the request defined it.
        definition: Raw,
        schema_digest: []const u8,
    } = null,
    @"error": ?[]const u8 = null,
    octoii: ?ItemExtension = null,
};

/// An item that adds tools from where it stands.
pub const AdditionalTools = struct {
    type: enum { additional_tools } = .additional_tools,
    id: ?[]const u8 = null,
    /// Who adds the tools, as the conversation's roles name them.
    role: enum { unknown, user, assistant, system, critic, discriminator, developer, tool },
    tools: []const Tool,
};

/// Octoii's item that takes functions away from where it stands, by name, as `additional_tools` adds them.
pub const ToolRemoval = struct {
    type: enum { @"octoii:tool_removal" } = .@"octoii:tool_removal",
    id: ?[]const u8 = null,
    names: []const []const u8,
};

/// How hard a text model reasons, from `none` to `max`.
pub const ReasoningEffort = enum { max, xhigh, high, medium, low, minimal, none };

/// An item that changes the reasoning effort from where it stands.
pub const ConfigurationUpdate = struct {
    type: enum { configuration_update } = .configuration_update,
    id: ?[]const u8 = null,
    reasoning: struct { effort: ReasoningEffort },
};

/// The conversation before it, compacted by the provider into content only its models read.
pub const Compaction = struct {
    type: enum { compaction } = .compaction,
    id: ?[]const u8 = null,
    encrypted_content: []const u8,
    octoii: ?ItemExtension = null,
};

/// The context before it, compacted by the provider into content only its models read.
pub const ContextCompaction = struct {
    type: enum { context_compaction } = .context_compaction,
    id: ?[]const u8 = null,
    encrypted_content: ?[]const u8 = null,
    octoii: ?ItemExtension = null,
};

/// A function call OpenRouter's armor blocked before it reached the caller, and why.
pub const ArmorBlocked = struct {
    type: enum { @"openrouter:armor_blocked" } = .@"openrouter:armor_blocked",
    id: []const u8,
    call_id: []const u8,
    name: []const u8,
    namespace: ?[]const u8 = null,
    arguments: []const u8,
    reason: []const u8,
    explanation: []const u8,
    status: enum { completed } = .completed,
    octoii: ?ItemExtension = null,
};

/// An item a response's output may hold: what the model, its provider or OpenRouter wrote.
pub const OutputItem = union(enum) {
    output_message: OutputMessage,
    function_call: FunctionCall,
    custom_tool_call: CustomToolCall,
    reasoning: ReasoningItem,
    web_search_call: WebSearchCall,
    openrouter_web_search: OpenRouterWebSearchCall,
    tool_search_call: ToolSearchCall,
    tool_search_output: ToolSearchOutput,
    openrouter_tool_search: OpenRouterToolSearchCall,
    compaction: Compaction,
    context_compaction: ContextCompaction,
    armor_blocked: ArmorBlocked,

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};

/// One unit of a conversation. A message is told apart by its role: an assistant's is the model's.
pub const Item = union(enum) {
    input_message: InputMessage,
    output_message: OutputMessage,
    function_call: FunctionCall,
    custom_tool_call: CustomToolCall,
    reasoning: ReasoningItem,
    web_search_call: WebSearchCall,
    openrouter_web_search: OpenRouterWebSearchCall,
    tool_search_call: ToolSearchCall,
    tool_search_output: ToolSearchOutput,
    openrouter_tool_search: OpenRouterToolSearchCall,
    compaction: Compaction,
    context_compaction: ContextCompaction,
    armor_blocked: ArmorBlocked,
    function_call_output: FunctionCallOutput,
    custom_tool_call_output: CustomToolCallOutput,
    additional_tools: AdditionalTools,
    tool_removal: ToolRemoval,
    configuration_update: ConfigurationUpdate,

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;

    /// An output item, as an item of the conversation that goes on from it.
    pub fn ofOutput(output: OutputItem) Item {
        return switch (output) {
            inline else => |payload, tag| @unionInit(Item, @tagName(tag), payload),
        };
    }
};

test "every output item is an item of the same name" {
    const outputs = @typeInfo(OutputItem).@"union";
    inline for (outputs.field_names, outputs.field_types) |name, Output| {
        try std.testing.expectEqual(Output, @FieldType(Item, name));
    }
}
