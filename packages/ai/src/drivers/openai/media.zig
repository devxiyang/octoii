//! What OpenAI's image and audio APIs share: a request sent with the API key and its refusal classified as a text
//! request's is; a request's `provider` held to OpenAI's own options; and the `error` events of its streams made the
//! vocabulary's.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const seam = @import("../../driver.zig");
const Call = seam.Call;
const failure_ = @import("../../failure.zig");
const Error = failure_.Error;
const http = @import("../../wire/http.zig");
const responses = @import("../../wire/responses.zig");
const openai = @import("../openai.zig");

/// A request to one of OpenAI's image and audio APIs: where to under its address, what it accepts, and its body.
pub const Request = struct {
    path: []const u8,
    accept: []const u8,
    method: std.http.Method = .POST,
    body: ?[]const u8 = null,
    content_type: []const u8 = "application/json",
};

/// Sends `request` to OpenAI with the API key; its answer once it is ok, else its refusal, classified by OpenAI's codes
/// and else its status.
pub fn send(call: *Call, request: Request) Error!foundation.http.Response {
    const key = try call.apiKey();
    const response = try http.send(call, .{
        .method = request.method,
        .url = try std.fmt.allocPrint(call.arena, "{s}{s}", .{ call.baseUrl(openai.base_url), request.path }),
        .headers = &.{
            .{ .name = "authorization", .value = try std.fmt.allocPrint(call.arena, "Bearer {s}", .{key}) },
            .{ .name = "accept", .value = request.accept },
            .{ .name = "content-type", .value = request.content_type },
        },
        .body = request.body,
    });
    if (response.status < 200 or response.status >= 300) return call.fail(try http.failureOf(call, response, details));
    return response;
}

fn details(arena: Allocator, body: []const u8) ?http.Details {
    return responses.openAiDetails(arena, body, openai.kindOf);
}

/// OpenAI's own settings of a request's `provider`, which its image and audio APIs take; `invalid_request` for any
/// other preference, routing or data policy, as OpenAI has none of them.
pub fn options(call: *Call, provider: anytype, comptime api: []const u8) Error!?std.json.ObjectMap {
    return @import("../../wire/json.zig").ownOptionsAlone(call, provider, "openai", "OpenAI's " ++ api ++ " takes no provider {s}: its provider takes options alone");
}

/// An `error` event of OpenAI's media streams: its error under `error`, or at its top.
const WireErrorEvent = struct {
    code: ?[]const u8 = null,
    message: ?[]const u8 = null,
    param: ?[]const u8 = null,
    @"error": ?struct { code: ?[]const u8 = null, message: ?[]const u8 = null, param: ?[]const u8 = null, type: ?[]const u8 = null } = null,
};

/// OpenAI's `error` event as the vocabulary's, its failure classified by its code, a code ai does not know being
/// `server`; null where `value` is no `error` event.
pub fn errorEvent(arena: Allocator, value: std.json.Value) ?vocabulary.media.MediaErrorEvent {
    const event = foundation.json.decodeValue(WireErrorEvent, arena, value) catch return null;
    const inner = event.@"error" orelse @TypeOf(event.@"error".?){};
    const code = inner.code orelse event.code;
    const kind = (if (code) |given| openai.kindOf(given) else null) orelse .server;
    return .{ .@"error" = .{
        .code = code orelse @tagName(kind),
        .message = inner.message orelse event.message orelse "The provider's stream failed without saying why",
        .param = inner.param orelse event.param,
        .type = inner.type,
        .octoii = .{ .kind = kind, .retryable = failure_.retryableKind(kind) },
    } };
}

/// Whether `response` streams server-sent events, by its `Content-Type`.
pub const streams = @import("../openrouter/media.zig").streams;

/// The JSON body of `response`, read as `T`.
pub const jsonBody = @import("../openrouter/media.zig").jsonBody;
