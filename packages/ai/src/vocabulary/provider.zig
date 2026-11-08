//! A request's `provider`: the settings of each provider's own, under its id in `options`, and OpenRouter's preferences
//! for routing a request among the providers that serve its model.
const foundation = @import("foundation");
const Raw = foundation.json.Raw;
const Variants = foundation.json.Variants;

/// The highest prices a request pays, in US dollars: for a million prompt or completion tokens, an image, a unit of
/// audio or a request.
pub const MaxPrice = struct {
    prompt: ?[]const u8 = null,
    completion: ?[]const u8 = null,
    image: ?[]const u8 = null,
    audio: ?[]const u8 = null,
    request: ?[]const u8 = null,
};

/// Cutoffs by percentile, over the last minutes of an endpoint's traffic.
pub const PercentileCutoffs = struct {
    p50: ?f64 = null,
    p75: ?f64 = null,
    p90: ?f64 = null,
    p99: ?f64 = null,
};

/// A bound on endpoints: a number for the median, or cutoffs by percentile.
pub const Cutoff = union(enum) {
    median: f64,
    percentiles: PercentileCutoffs,

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};

/// What OpenRouter sorts the endpoints of a model by.
pub const ProviderSort = enum { price, throughput, latency, exacto };

/// How OpenRouter sorts endpoints: by one measure, or by one within each model or across them all.
pub const Sort = union(enum) {
    by: ProviderSort,
    partitioned: struct {
        by: ?ProviderSort = null,
        /// `model` sorts each model's endpoints apart, keeping fallback models as fallbacks; `none` sorts them all
        /// together.
        partition: ?enum { model, none } = null,
    },

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};

/// The numeric precision an endpoint serves a model at.
pub const Quantization = enum { int4, int8, fp4, mxfp4, nvfp4, fp6, fp8, mxfp8, fp16, bf16, fp32, unknown };

/// A request's `provider`: `options` for every provider, each reading its own, and OpenRouter's routing preferences,
/// which work at OpenRouter alone. Providers are named by OpenRouter's slugs, such as `anthropic` or `google-vertex`.
pub const ProviderPreferences = struct {
    /// Each provider's own settings, an object under its id, such as `anthropic`.
    options: ?Raw = null,
    /// Whether OpenRouter may try other providers when the preferred ones fail.
    allow_fallbacks: ?bool = null,
    /// Whether providers that may keep and train on the request are allowed.
    data_collection: ?enum { allow, deny } = null,
    /// Only models whose output their authors allow distilling.
    enforce_distillable_text: ?bool = null,
    /// Providers never used.
    ignore: ?[]const []const u8 = null,
    max_price: ?MaxPrice = null,
    /// The only providers used.
    only: ?[]const []const u8 = null,
    /// Providers tried first, in this order.
    order: ?[]const []const u8 = null,
    /// Endpoints slower than this, in seconds, are tried last.
    preferred_max_latency: ?Cutoff = null,
    /// Endpoints with fewer tokens a second than this are tried last.
    preferred_min_throughput: ?Cutoff = null,
    quantizations: ?[]const Quantization = null,
    /// Only providers that take every parameter of the request.
    require_parameters: ?bool = null,
    sort: ?Sort = null,
    /// Only endpoints that keep no data.
    zdr: ?bool = null,
};
