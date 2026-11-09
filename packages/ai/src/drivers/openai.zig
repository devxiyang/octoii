//! `openai`: OpenAI's Responses API, which the vocabulary is, reached with an API key. A request goes as OpenAI's
//! Responses API takes it, kept nowhere, with explicit caching for the models that take it; its events come back as
//! they are, but for its errors, classified by OpenAI's codes, and the searches its usage does not count.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const seam = @import("../driver.zig");
const failure_ = @import("../failure.zig");
const Error = failure_.Error;
const Kind = failure_.Kind;
const Model = @import("../catalogue/model.zig").Model;
const check = @import("../text/check.zig");
const http = @import("../wire/http.zig");
const responses = @import("../wire/responses.zig");
const source = @import("../wire/source.zig");

/// Where OpenAI's API is.
pub const base_url = "https://api.openai.com/v1";

pub const driver: seam.Driver = .{ .id = "openai", .name = "OpenAI", .catalogue = "openai", .text = text, .image = @import("openai/images.zig").make, .speech = @import("openai/speech.zig").speak, .transcription = @import("openai/transcriptions.zig").transcribe, .voices = @import("openai/voices.zig").calls, .realtime = @import("openai/realtime.zig").calls };

/// The parts that work only at some providers which OpenAI takes.
const parts = [_]check.Part{ .custom_tools, .namespaces, .tool_search, .truncation };

/// The failure kind of each of OpenAI's codes and error types.
const kinds = std.StaticStringMap(Kind).initComptime(.{
    .{ "context_length_exceeded", .context_overflow },      .{ "image_too_large", .payload_too_large },
    .{ "image_file_too_large", .payload_too_large },        .{ "insufficient_quota", .quota },
    .{ "credit_balance_exhausted", .quota },                .{ "organization_spend_limit_exceeded", .quota },
    .{ "project_spend_limit_exceeded", .quota },            .{ "organization_usage_limit_exceeded", .quota },
    .{ "rate_limit_exceeded", .rate_limit },                .{ "slow_down", .rate_limit },
    .{ "invalid_api_key", .auth },                          .{ "bio_policy", .content_filter },
    .{ "cyber_policy", .content_filter },                   .{ "misalignment_policy_violation", .content_filter },
    .{ "image_content_policy_violation", .content_filter }, .{ "moderation_blocked", .content_filter },
    .{ "server_error", .server },                           .{ "server_is_overloaded", .server },
    .{ "vector_store_timeout", .server },                   .{ "invalid_prompt", .invalid_request },
    .{ "data_residency_mismatch", .invalid_request },       .{ "invalid_image", .invalid_request },
    .{ "invalid_image_format", .invalid_request },          .{ "invalid_base64_image", .invalid_request },
    .{ "invalid_image_url", .invalid_request },             .{ "image_too_small", .invalid_request },
    .{ "image_parse_error", .invalid_request },             .{ "invalid_image_mode", .invalid_request },
    .{ "unsupported_image_media_type", .invalid_request },  .{ "empty_image_file", .invalid_request },
    .{ "failed_to_download_image", .invalid_request },      .{ "image_file_not_found", .invalid_request },
});

/// The failure kind of one of OpenAI's codes or error types; null for another.
pub fn kindOf(code: []const u8) ?Kind {
    return kinds.get(code);
}

/// Whether `model` takes explicit caching: OpenAI's models that do are those that price their cache writes.
fn takesExplicitCaching(model: *const Model) bool {
    const pricing = model.pricing orelse return false;
    return pricing.input_cache_write != null;
}

/// The request as it goes to OpenAI for `model`: as its Responses API takes it, its breakpoints only where it caches
/// at them.
pub fn wireRequest(arena: Allocator, model: *const Model, request: vocabulary.ResponsesRequest) Allocator.Error![]const u8 {
    const sent = if (takesExplicitCaching(model)) request else try responses.withoutExplicitCaching(arena, request);
    return responses.openAiRequest(arena, model, sent, "openai");
}

fn text(call: *seam.Call, model: *const Model, request: *const vocabulary.ResponsesRequest) Error!seam.TextSource {
    try check.parts(call, model, request, &parts);
    try responses.checkOpenAi(call, request, "openai");
    if (request.service_tier) |tier| if (tier != .auto and tier != .default) {
        return call.failWith(.invalid_request, "The provider openai is not asked for the service tier {t}: the catalogue prices the default tier alone", .{tier});
    };
    const key = try call.apiKey();
    const response = try http.send(call, .{
        .method = .POST,
        .url = try call.arena.print("{s}/responses", .{call.baseUrl(base_url)}),
        .headers = &.{
            .{ .name = "authorization", .value = try call.arena.print("Bearer {s}", .{key}) },
            .{ .name = "accept", .value = "text/event-stream" },
            .{ .name = "content-type", .value = "application/json" },
        },
        .body = try wireRequest(call.arena, model, request.*),
    });
    if (response.status < 200 or response.status >= 300) return call.fail(try http.failureOf(call, response, details));
    return source.of(vocabulary.ResponseStreamEvent, call, response, translate);
}

fn details(arena: Allocator, body: []const u8) ?http.Details {
    return responses.openAiDetails(arena, body, kindOf);
}

fn translate(call: *seam.Call, data: []const u8, out: *std.ArrayList(vocabulary.ResponseStreamEvent)) Error!void {
    if (try responses.openAiEvent(call, data, kindOf)) |event| try out.append(call.arena, event);
}
