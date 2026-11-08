//! OpenRouter's decision kind: its Decisions API, which the vocabulary is, at `/api/alpha/decisions`, beside its other
//! APIs under `/api/v1`. A request goes as it is, the model by its id, and its answer comes back as it is.
const std = @import("std");
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const decisions = vocabulary.decisions;
const seam = @import("../../driver.zig");
const Call = seam.Call;
const Error = @import("../../failure.zig").Error;
const Model = @import("../../catalogue/model.zig").Model;
const http = @import("../../wire/http.zig");
const openrouter = @import("../openrouter.zig");
const media = @import("media.zig");

/// The address the Decisions API stands under: `base_url` with its last segment, `v1`, as `alpha`.
pub fn baseUrl(arena: std.mem.Allocator, base_url: []const u8) std.mem.Allocator.Error![]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, base_url, '/') orelse base_url.len;
    return std.fmt.allocPrint(arena, "{s}/alpha", .{base_url[0..slash]});
}

pub fn decide(call: *Call, model: *const Model, request: *const decisions.DecisionsRequest) Error!decisions.DecisionsResponse {
    var sent = request.*;
    sent.model = model.id;
    const key = try call.apiKey();
    const response = try http.send(call, .{
        .method = .POST,
        .url = try std.fmt.allocPrint(call.arena, "{s}/decisions", .{try baseUrl(call.arena, call.baseUrl(openrouter.base_url))}),
        .headers = &.{
            .{ .name = "authorization", .value = try std.fmt.allocPrint(call.arena, "Bearer {s}", .{key}) },
            .{ .name = "accept", .value = "application/json" },
            .{ .name = "content-type", .value = "application/json" },
        },
        .body = try foundation.json.encode(call.arena, sent),
    });
    if (response.status < 200 or response.status >= 300) return call.fail(try http.failureOf(call, response, openrouter.details));
    return media.jsonBody(decisions.DecisionsResponse, call, response, "decisions response");
}
