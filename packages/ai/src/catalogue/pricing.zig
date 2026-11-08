//! What a request costs at its model's prices: the prices that apply to it, by its input and the time it was sent, and
//! each meter of its usage at its price, a result's own price once. A cost is the provider's or the catalogue's, never
//! a guess: where a price is unknown, so is the cost.
const std = @import("std");
const model_ = @import("model.zig");
const Model = model_.Model;
const Pricing = model_.Pricing;
const PricingOverride = model_.PricingOverride;
const Usage = @import("vocabulary").Usage;

/// What decides the prices a usage is charged at, besides the usage.
pub const Conditions = struct {
    /// The input of the last request of a response continued over several; none, the usage's input meters added up.
    context_tokens: ?u64 = null,
    /// When the request was sent, in ms since the epoch.
    sent_at_ms: i64,
};

/// The token prices a model lists, by name.
const Price = enum { prompt, completion, input_cache_read, input_cache_write, input_cache_write_1h, internal_reasoning, audio, audio_output, input_audio_cache, image, image_token, image_output, web_search, request };

/// The prices listed for a request: the base ones, each replaced by the overrides that apply, a later one's winning.
const Listed = std.EnumArray(Price, ?[]const u8);

/// What `usage` cost in US dollars at the model's prices that applied to its request, each meter at its price, the
/// seconds and characters at a unit's price, a result's own price once; null where it cannot be priced: a model
/// without prices, a usage that counts nothing the model prices, or a price a counting meter needs that cannot be read.
pub fn cost(model: *const Model, usage: Usage, conditions: Conditions) ?f64 {
    const pricing = model.pricing orelse return null;
    const listed = listedPrices(pricing, conditions.context_tokens orelse usage.inputTokens(), conditions.sent_at_ms);
    const discount = pricing.discount orelse 0;
    const second = if (pricing.octoii) |units| units.second else null;
    const character = if (pricing.octoii) |units| units.character else null;
    // A model that names a unit's price bills by that unit, and the tokens its usage counts beside it only describe it.
    const bills_by_unit = second != null or character != null;
    var total: f64 = 0;
    var priced = false;
    var charged = std.EnumArray(Price, f64).initFill(0);
    const output: f64 = @floatFromInt(usage.output orelse 0);
    const reasoning: f64 = if (listed.get(.internal_reasoning) == null) 0 else @min(@as(f64, @floatFromInt(usage.reasoning orelse 0)), output);
    const meters = [_]struct { Price, ?u64 }{
        .{ .prompt, usage.input },                          .{ .input_cache_read, usage.cache_read },
        .{ .input_audio_cache, usage.cache_read_audio },    .{ .input_cache_write, usage.cache_write },
        .{ .input_cache_write_1h, usage.cache_write_long }, .{ .audio, usage.input_audio },
        .{ .audio_output, usage.output_audio },             .{ .image_token, usage.input_image },
        .{ .image_output, usage.output_image },             .{ .image, usage.images_read },
        .{ .image_output, usage.images_made },              .{ .web_search, usage.web_searches },
    };
    for (meters) |meter| if (meter[1]) |amount| {
        charged.getPtr(meter[0]).* += @floatFromInt(amount);
    };
    charged.getPtr(.completion).* += output - reasoning;
    charged.getPtr(.internal_reasoning).* += reasoning;
    // A result pays its own price once, though a paused answer continued over several requests adds them into one.
    charged.getPtr(.request).* += 1;
    for (std.enums.values(Price)) |name| {
        const amount = charged.get(name);
        if (amount <= 0) continue;
        const text = listed.get(name) orelse continue;
        const price = readPrice(text, discount) orelse return null;
        total += amount * price;
        priced = priced or !bills_by_unit;
    }
    const unit_meters = [_]struct { ?f64, ?[]const u8 }{
        .{ usage.seconds, second },
        .{ if (usage.characters) |characters| @floatFromInt(characters) else null, character },
    };
    for (unit_meters) |meter| {
        const amount = meter[0] orelse continue;
        const text = meter[1] orelse continue;
        if (amount <= 0) continue;
        total += amount * (readPrice(text, discount) orelse return null);
        priced = true;
    }
    return if (priced) total else null;
}

fn listedPrices(pricing: Pricing, input_tokens: u64, sent_at_ms: i64) Listed {
    var listed = Listed.initFill(null);
    inline for (comptime std.enums.values(Price)) |name| listed.set(name, @field(pricing, @tagName(name)));
    for (pricing.overrides orelse &.{}) |override| {
        if (!applies(override, input_tokens, sent_at_ms)) continue;
        inline for (comptime std.enums.values(Price)) |name| {
            if (@hasField(PricingOverride, @tagName(name))) {
                if (@field(override, @tagName(name))) |price| listed.set(name, price);
            }
        }
    }
    return listed;
}

/// A listed price as a number with `discount` taken off; null where it cannot be read, as a router's "-1" for a price
/// that varies.
fn readPrice(text: []const u8, discount: f64) ?f64 {
    if (text.len == 0 or !std.ascii.isDigit(text[0])) return null;
    const price = std.fmt.parseFloat(f64, text) catch return null;
    if (!std.math.isFinite(price) or price < 0) return null;
    return price * (1 - discount);
}

/// Whether every condition of `override` holds for a request of `input_tokens` sent at `sent_at_ms`.
fn applies(override: PricingOverride, input_tokens: u64, sent_at_ms: i64) bool {
    if (override.min_prompt_tokens) |least| if (input_tokens <= least) return false;
    const seconds: u64 = @intCast(@divFloor(sent_at_ms, 1000));
    const days = seconds / std.time.s_per_day;
    // 1970-01-01 was a Thursday.
    const day: model_.UtcDay = @fromBackingInt(@intCast((days + 3) % 7));
    if (override.utc_days) |listed| if (std.mem.indexOfScalar(model_.UtcDay, listed, day) == null) return false;
    const of_day = seconds % std.time.s_per_day;
    const time: u32 = @intCast(of_day / 3600 * 100 + of_day % 3600 / 60);
    const start = override.utc_start orelse 0;
    const end = override.utc_end orelse 2400;
    // A window that ends before it starts wraps past midnight.
    return if (start <= end) start <= time and time < end else start <= time or time < end;
}

test "a usage costs each meter at its price, reasoning apart where priced, and overrides by input and time" {
    const model: Model = .{
        .id = "m",
        .name = "M",
        .architecture = .{ .input_modalities = &.{.text}, .output_modalities = &.{.text} },
        .pricing = .{
            .prompt = "0.000001",
            .completion = "0.000002",
            .input_cache_read = "0.0000001",
            .web_search = "0.01",
            .overrides = &.{
                .{ .min_prompt_tokens = 1000, .prompt = "0.000003" },
                .{ .utc_days = &.{.thursday}, .utc_start = 2200, .utc_end = 200, .completion = "0.000001" },
            },
        },
        .octoii = .{ .provider = "p", .kinds = &.{.text} },
    };
    // Wed, 28 Oct 2026 12:00:00 GMT, and Thu, 29 Oct 2026 23:00:00 GMT.
    const wednesday: i64 = 1_793_188_800_000;
    const thursday_night: i64 = 1_793_314_800_000;
    const usage: Usage = .{ .input = 100, .cache_read = 50, .output = 10, .web_searches = 1 };
    try std.testing.expectApproxEqAbs(@as(f64, 100 * 0.000001 + 50 * 0.0000001 + 10 * 0.000002 + 0.01), cost(&model, usage, .{ .sent_at_ms = wednesday }).?, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 100 * 0.000003 + 50 * 0.0000001 + 10 * 0.000002 + 0.01), cost(&model, usage, .{ .sent_at_ms = wednesday, .context_tokens = 2000 }).?, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 100 * 0.000001 + 50 * 0.0000001 + 10 * 0.000001 + 0.01), cost(&model, usage, .{ .sent_at_ms = thursday_night }).?, 1e-15);
    var unpriced = model;
    unpriced.pricing = null;
    try std.testing.expectEqual(null, cost(&unpriced, usage, .{ .sent_at_ms = wednesday }));
    var varying = model;
    varying.pricing.?.completion = "-1";
    try std.testing.expectEqual(null, cost(&varying, usage, .{ .sent_at_ms = wednesday }));
}
