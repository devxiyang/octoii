//! `meta`: the Responses API of Meta's Model API, reached with an API key, kept nowhere. A request goes as OpenAI's
//! Responses API takes it, its reasoning asked for with its encrypted content so a later request goes on from it; its
//! events come back as they are, but for its errors, classified by Meta's codes.
const std = @import("std");
const Allocator = std.mem.Allocator;
const vocabulary = @import("vocabulary");
const Request = vocabulary.ResponsesRequest;
const seam = @import("../driver.zig");
const failure_ = @import("../failure.zig");
const Error = failure_.Error;
const Model = @import("../catalogue/model.zig").Model;
const check = @import("../text/check.zig");
const http = @import("../wire/http.zig");
const responses = @import("../wire/responses.zig");
const source = @import("../wire/source.zig");

/// Where Meta's Model API is.
pub const base_url = "https://api.meta.ai/v1";

pub const driver: seam.Driver = .{ .id = "meta", .name = "Meta", .catalogue = "meta", .text = text };

/// The kind of each code and type Meta's errors carry.
const kinds = std.StaticStringMap(failure_.Kind).initComptime(.{
    .{ "invalid_api_key", .auth },                  .{ "authentication_error", .auth },
    .{ "billing_not_configured", .quota },          .{ "billing_error", .quota },
    .{ "rate_limit_exceeded", .rate_limit },        .{ "rate_limit_error", .rate_limit },
    .{ "payload_too_large", .payload_too_large },   .{ "content_policy_violation", .content_filter },
    .{ "service_overloaded", .server },             .{ "backend_unavailable", .server },
    .{ "server_shutting_down", .server },           .{ "gateway_timeout", .server },
    .{ "server_error", .server },                   .{ "model_not_found", .invalid_request },
    .{ "invalid_request_error", .invalid_request },
});

fn kindOf(code: []const u8) ?failure_.Kind {
    return kinds.get(code);
}

/// The request as it goes to Meta for `model`: as OpenAI's Responses API takes it, without explicit caching, which
/// Meta does on its own, and asking a reasoning model for its reasoning's encrypted content.
pub fn wireRequest(arena: Allocator, model: *const Model, request: Request) Allocator.Error![]const u8 {
    var sent = try responses.withoutExplicitCaching(arena, request);
    var include: std.ArrayList(vocabulary.request.ResponseIncludable) = .empty;
    for (sent.include orelse &.{}) |value| if (std.mem.indexOfScalar(vocabulary.request.ResponseIncludable, include.items, value) == null) try include.append(arena, value);
    if (model.reasons() != false and std.mem.indexOfScalar(vocabulary.request.ResponseIncludable, include.items, .@"reasoning.encrypted_content") == null) try include.append(arena, .@"reasoning.encrypted_content");
    sent.include = if (include.items.len == 0) null else include.items;
    return responses.openAiRequest(arena, model, sent, "meta");
}

fn text(call: *seam.Call, model: *const Model, request: *const Request) Error!seam.TextSource {
    try check.parts(call, model, request, &.{ .custom_tools, .tool_search });
    try responses.checkOpenAi(call, request, "meta");
    const key = try call.apiKey();
    const response = try http.send(call, .{
        .method = .POST,
        .url = try std.fmt.allocPrint(call.arena, "{s}/responses", .{call.baseUrl(base_url)}),
        .headers = &.{
            .{ .name = "authorization", .value = try std.fmt.allocPrint(call.arena, "Bearer {s}", .{key}) },
            .{ .name = "accept", .value = "text/event-stream" },
            .{ .name = "content-type", .value = "application/json" },
        },
        .body = try wireRequest(call.arena, model, request.*),
    });
    if (response.status < 200 or response.status >= 300) return call.fail(try http.failureOf(call, response, details));
    return source.of(vocabulary.ResponseStreamEvent, call, response, translate);
}

/// What a body of Meta's says of a refusal, as OpenAI's body says it, its kind by Meta's codes; one whose message
/// says the context is too long is `context_overflow`, as Meta gives it no code.
fn details(arena: Allocator, body: []const u8) ?http.Details {
    var given = responses.openAiDetails(arena, body, kindOf) orelse return null;
    if (responses.contextTooLong(given.message)) given.kind = .context_overflow;
    return given;
}

fn translate(call: *seam.Call, data: []const u8, out: *std.ArrayList(vocabulary.ResponseStreamEvent)) Error!void {
    if (try responses.openAiEvent(call, data, kindOf)) |event| try out.append(call.arena, event);
}
