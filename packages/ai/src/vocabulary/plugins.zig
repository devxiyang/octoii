//! OpenRouter's plugins: features OpenRouter runs around a request, each named by its `id`, which work at OpenRouter
//! alone. Its fusion and web fetch plugins are left out: they run tools the vocabulary leaves out with their items and
//! events.
const foundation = @import("foundation");
const Raw = foundation.json.Raw;
const Variants = foundation.json.Variants;
const tools = @import("tools.zig");

/// Whether a plugin acts on what it finds (`enforce`) or reports it alone (`audit`).
pub const PluginMode = enum { enforce, audit };

/// How much an automatic choice of the model may spend.
pub const CostTier = enum { low, medium, high, xhigh, max };

/// Rules OpenRouter checks each answer against, retrying or blocking one that breaks them.
pub const AlignmentPlugin = struct {
    id: enum { alignment } = .alignment,
    rules: []const struct {
        rule: []const u8,
        watch: []const enum { content, tool_calls, refusal, images, audio },
    },
    mode: ?PluginMode = null,
    instruct: ?bool = null,
    max_retries: ?u32 = null,
    threshold: ?f64 = null,
};

/// OpenRouter's check of the function calls a model makes, which blocks the dangerous ones.
pub const ArmorPlugin = struct {
    id: enum { armor } = .armor,
    enabled: ?bool = null,
    mode: ?PluginMode = null,
    on_error: ?enum { log, block } = null,
    output_mode: ?enum { text, custom_item, claude_code_compatibility } = null,
    /// What the check knows of where the calls run, and its rules.
    classifier_context: ?Raw = null,
    evaluate_native_tools: ?bool = null,
    use_cc_style_default_rules: ?bool = null,
};

/// OpenRouter's choice of the model for each request.
pub const AutoRouterPlugin = struct {
    id: enum { @"auto-router" } = .@"auto-router",
    enabled: ?bool = null,
    allowed_models: ?[]const []const u8 = null,
    excluded_models: ?[]const []const u8 = null,
    cost_tier: ?CostTier = null,
    pin_model: ?bool = null,
};

/// The version of OpenRouter's choice of the model it is trying out.
pub const AutoBetaRouterPlugin = struct {
    id: enum { @"auto-beta-router" } = .@"auto-beta-router",
    enabled: ?bool = null,
    allowed_models: ?[]const []const u8 = null,
    excluded_models: ?[]const []const u8 = null,
    cost_tier: ?CostTier = null,
};

/// OpenRouter's compression of a context too long for the model.
pub const ContextCompressionPlugin = struct {
    id: enum { @"context-compression" } = .@"context-compression",
    enabled: ?bool = null,
    engine: ?enum { @"middle-out" } = null,
};

/// OpenRouter's reading of files, such as PDFs, for models that cannot read them.
pub const FileParserPlugin = struct {
    id: enum { @"file-parser" } = .@"file-parser",
    enabled: ?bool = null,
    pdf: ?struct { engine: ?enum { @"pdf-text", @"mistral-ocr", native, @"cloudflare-ai" } = null } = null,
};

/// OpenRouter's choice of the model among those given.
pub const JevRouterPlugin = struct {
    id: enum { @"jev-router" } = .@"jev-router",
    models: ?[]const []const u8 = null,
    allowed_models: ?[]const []const u8 = null,
    excluded_models: ?[]const []const u8 = null,
    cost_tier: ?[]const u8 = null,
};

/// OpenRouter's moderation of a request.
pub const ModerationPlugin = struct {
    id: enum { moderation } = .moderation,
};

/// OpenRouter's choice of the model best for its price.
pub const ParetoRouterPlugin = struct {
    id: enum { @"pareto-router" } = .@"pareto-router",
    enabled: ?bool = null,
    max_price: ?f64 = null,
    min_coding_score: ?f64 = null,
    price_source: ?enum { prompt, weighted_avg } = null,
};

/// OpenRouter's repair of structured output that is not valid JSON.
pub const ResponseHealingPlugin = struct {
    id: enum { @"response-healing" } = .@"response-healing",
    enabled: ?bool = null,
};

/// OpenRouter's choice of the model by an algorithm.
pub const SwitchyardRouterPlugin = struct {
    id: enum { @"switchyard-router" } = .@"switchyard-router",
    algorithm: ?enum { capability, stage, auto, random, composite, passthrough } = null,
    judge_model: ?[]const u8 = null,
};

/// OpenRouter's web search for a model, whose results it gives the model before it answers.
pub const WebSearchPlugin = struct {
    id: enum { web } = .web,
    enabled: ?bool = null,
    engine: ?enum { native, exa, firecrawl, parallel, perplexity } = null,
    include_domains: ?[]const []const u8 = null,
    exclude_domains: ?[]const []const u8 = null,
    max_results: ?u32 = null,
    max_uses: ?u32 = null,
    mode: ?tools.WebSearchMode = null,
    search_prompt: ?[]const u8 = null,
    user_location: ?tools.WebSearchUserLocation = null,
    x_search: ?tools.XSearchOptions = null,
};

/// A feature OpenRouter runs around a request.
pub const Plugin = union(enum) {
    alignment: AlignmentPlugin,
    armor: ArmorPlugin,
    auto_beta_router: AutoBetaRouterPlugin,
    auto_router: AutoRouterPlugin,
    context_compression: ContextCompressionPlugin,
    file_parser: FileParserPlugin,
    jev_router: JevRouterPlugin,
    moderation: ModerationPlugin,
    pareto_router: ParetoRouterPlugin,
    response_healing: ResponseHealingPlugin,
    switchyard_router: SwitchyardRouterPlugin,
    web: WebSearchPlugin,

    const variants = Variants(@This(), "id");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};
