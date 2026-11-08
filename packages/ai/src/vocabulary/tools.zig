//! What a model may use — functions the caller runs, custom tools, namespaces of them, and the hosted tools the
//! vocabulary takes, web search and the search for deferred tools — and how a request chooses among them.
const foundation = @import("foundation");
const Raw = foundation.json.Raw;
const Variants = foundation.json.Variants;

/// Who may call a function: the model itself, or a program the model writes.
pub const AllowedCaller = enum { direct, programmatic };

/// A function the caller runs, which the model may call: its name, description and parameters. Within a namespace,
/// its parameters may be left out.
pub const FunctionTool = struct {
    type: enum { function } = .function,
    name: []const u8,
    description: ?[]const u8 = null,
    /// The JSON Schema of the arguments.
    parameters: ?Raw = null,
    strict: ?bool = null,
    allowed_callers: ?[]const AllowedCaller = null,
    /// The model goes on without waiting for the output, which a later request gives with the call's `call_id`.
    async: ?bool = null,
    /// Withheld from the model until the search for deferred tools finds it.
    defer_loading: ?bool = null,
    /// The JSON Schema of the function's output.
    output_schema: ?Raw = null,
};

/// The form of a custom tool's input: free text, or text of a grammar.
pub const CustomToolFormat = union(enum) {
    text: struct { type: enum { text } = .text },
    grammar: struct {
        type: enum { grammar } = .grammar,
        syntax: enum { lark, regex },
        definition: []const u8,
    },

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};

/// A tool the caller runs whose input is text rather than JSON arguments.
pub const CustomTool = struct {
    type: enum { custom } = .custom,
    name: []const u8,
    description: ?[]const u8 = null,
    format: ?CustomToolFormat = null,
    async: ?bool = null,
    defer_loading: ?bool = null,
};

/// What a namespace groups: functions and custom tools.
pub const NamespaceMember = union(enum) {
    function: FunctionTool,
    custom: CustomTool,

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};

/// Functions and custom tools grouped under a name, which their calls carry as `namespace`.
pub const NamespaceTool = struct {
    type: enum { namespace } = .namespace,
    name: []const u8,
    description: []const u8,
    tools: []const NamespaceMember,
};

/// Which engine a web search uses: the provider's own (`native`), or a search service OpenRouter runs.
pub const WebSearchEngine = enum { auto, native, exa, parallel, firecrawl, perplexity };

/// A search engine's own mode, where it has them.
pub const WebSearchMode = enum { instant, fast, auto, @"deep-lite", deep, @"deep-reasoning", turbo, basic, advanced };

/// How much of each result a web search reads.
pub const SearchContextSize = enum { low, medium, high };

/// Where the person searching roughly is.
pub const WebSearchUserLocation = struct {
    type: ?enum { approximate } = null,
    city: ?[]const u8 = null,
    country: ?[]const u8 = null,
    region: ?[]const u8 = null,
    timezone: ?[]const u8 = null,
};

/// The domains a web search keeps to or leaves out.
pub const WebSearchDomainFilter = struct {
    allowed_domains: ?[]const []const u8 = null,
    blocked_domains: ?[]const []const u8 = null,
    excluded_domains: ?[]const []const u8 = null,
};

/// A search of posts on X, for the models that search it.
pub const XSearchOptions = struct {
    allowed_x_handles: ?[]const []const u8 = null,
    excluded_x_handles: ?[]const []const u8 = null,
    enable_image_understanding: ?bool = null,
    enable_video_understanding: ?bool = null,
    /// The first day of the posts, as an ISO 8601 date such as `2026-01-01`.
    from_date: ?[]const u8 = null,
    /// The last day of the posts, as an ISO 8601 date.
    to_date: ?[]const u8 = null,
};

/// The provider's web search, as the Responses API names it, `web_search` or its dated form.
pub const WebSearchTool = struct {
    type: enum { web_search, web_search_2025_08_26 } = .web_search,
    engine: ?WebSearchEngine = null,
    filters: ?WebSearchDomainFilter = null,
    max_results: ?u32 = null,
    max_uses: ?u32 = null,
    mode: ?WebSearchMode = null,
    search_context_size: ?SearchContextSize = null,
    user_location: ?WebSearchUserLocation = null,
    x_search: ?XSearchOptions = null,
};

/// The settings of OpenRouter's web search.
pub const OpenRouterWebSearchParameters = struct {
    engine: ?WebSearchEngine = null,
    allowed_domains: ?[]const []const u8 = null,
    excluded_domains: ?[]const []const u8 = null,
    /// The most characters of each result.
    max_characters: ?u32 = null,
    /// The most results of each search.
    max_results: ?u32 = null,
    /// The most results of every search together.
    max_total_results: ?u32 = null,
    /// The most searches a request makes.
    max_uses: ?u32 = null,
    mode: ?WebSearchMode = null,
    search_context_size: ?SearchContextSize = null,
    user_location: ?WebSearchUserLocation = null,
    x_search: ?XSearchOptions = null,
};

/// OpenRouter's web search, which works with any model it serves.
pub const OpenRouterWebSearchTool = struct {
    type: enum { @"openrouter:web_search" } = .@"openrouter:web_search",
    parameters: ?OpenRouterWebSearchParameters = null,
};

/// The search for deferred tools, which finds the functions a request withholds with `defer_loading`.
pub const ToolSearchTool = struct {
    type: enum { @"openrouter:tool_search" } = .@"openrouter:tool_search",
    parameters: ?struct { max_results: ?u32 = null } = null,
};

/// What a model may use.
pub const Tool = union(enum) {
    function: FunctionTool,
    custom: CustomTool,
    namespace: NamespaceTool,
    web_search: WebSearchTool,
    openrouter_web_search: OpenRouterWebSearchTool,
    tool_search: ToolSearchTool,

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};

/// A choice of one function the model must call.
pub const FunctionToolChoice = struct {
    type: enum { function } = .function,
    name: []const u8,
};

/// A choice that keeps the model to some of the request's tools, which it may (`auto`) or must (`required`) use.
pub const AllowedToolsChoice = struct {
    type: enum { allowed_tools } = .allowed_tools,
    mode: enum { auto, required },
    /// The tools allowed, each as a tool choice names one, such as `{"type":"function","name":"search"}`.
    tools: []const Raw,
};

/// Whether and which tools the model uses: as it sees fit (`auto`), none, at least one (`required`), or those named.
pub const ToolChoice = union(enum) {
    mode: enum { auto, none, required },
    function: FunctionToolChoice,
    allowed_tools: AllowedToolsChoice,

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};
