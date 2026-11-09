//! What OpenRouter's media and Decisions APIs share: a request sent with the API key and its refusal classified as a
//! text request's is, a request's `provider` held to what an API takes, and the `error` events of its streams made
//! the vocabulary's.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const seam = @import("../../driver.zig");
const Call = seam.Call;
const Error = @import("../../failure.zig").Error;
const http = @import("../../wire/http.zig");
const openrouter = @import("../openrouter.zig");

/// What a speech or transcription request's `provider` takes at OpenRouter: its data policy and each provider's
/// options.
pub const data_policy = [_][]const u8{ "zdr", "data_collection", "options" };

/// Sends `body` to `path` at OpenRouter with the API key, accepting `accept`; its answer once it is ok, else its
/// refusal, classified by its body and status.
pub fn send(call: *Call, path: []const u8, body: ?[]const u8, accept: []const u8) Error!foundation.http.Response {
    const key = try call.apiKey();
    const response = try http.send(call, .{
        .method = if (body == null) .GET else .POST,
        .url = try call.arena.print("{s}{s}", .{ call.baseUrl(openrouter.base_url), path }),
        .headers = &.{
            .{ .name = "authorization", .value = try call.arena.print("Bearer {s}", .{key}) },
            .{ .name = "accept", .value = accept },
            .{ .name = "content-type", .value = "application/json" },
        },
        .body = body,
    });
    if (response.status < 200 or response.status >= 300) return call.fail(try http.failureOf(call, response, openrouter.details));
    return response;
}

/// An `error` event of OpenRouter's media streams, its failure not yet classified.
const WireErrorEvent = struct {
    @"error": struct {
        code: ?openrouter.Code = null,
        message: []const u8,
        param: ?[]const u8 = null,
        type: ?[]const u8 = null,
        metadata: ?std.json.Value = null,
    },
};

/// OpenRouter's `error` event, the data `data`, as the vocabulary's, its failure classified by its code; null where
/// the data is no `error` event.
pub fn errorEvent(arena: Allocator, data: []const u8) Allocator.Error!?vocabulary.media.MediaErrorEvent {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{ .allocate = .alloc_always }) catch return null;
    if (parsed != .object) return null;
    const kind = parsed.object.get("type") orelse return null;
    if (kind != .string or !std.mem.eql(u8, kind.string, "error")) return null;
    const event = foundation.json.decodeValue(WireErrorEvent, arena, parsed) catch return null;
    const given = event.@"error";
    const octoii = openrouter.classified(given.code, null);
    const message = try openrouter.wireErrorMessage(arena, .{ .code = given.code, .message = given.message, .metadata = given.metadata });
    return .{ .@"error" = .{
        .code = if (given.code) |code| (if (code == .name) code.name else @tagName(octoii.kind)) else @tagName(octoii.kind),
        .message = message orelse given.message,
        .param = given.param,
        .type = given.type,
        .octoii = octoii,
    } };
}

/// Checks that a request's `provider` sets only what the API it goes to takes, `taken`, naming the rest, as OpenRouter
/// would ignore them.
pub fn checkProviderFields(call: *Call, provider: ?vocabulary.provider.ProviderPreferences, comptime taken: []const []const u8, api: []const u8) Error!void {
    const given = provider orelse return;
    var others: std.ArrayList([]const u8) = .empty;
    inline for (comptime std.meta.fieldNames(vocabulary.provider.ProviderPreferences)) |name| {
        const listed = comptime for (taken) |each| {
            if (std.mem.eql(u8, each, name)) break true;
        } else false;
        if (!listed and @field(given, name) != null) try others.append(call.arena, name);
    }
    if (others.items.len == 0) return;
    return call.failWith(.invalid_request, "OpenRouter's {s} takes no provider {s}: its provider takes {s}", .{ api, try std.mem.join(call.arena, ", ", others.items), try std.mem.join(call.arena, ", ", taken) });
}

/// Whether `response` streams server-sent events, by its `Content-Type`.
pub fn streams(response: foundation.http.Response) bool {
    const given = response.header("content-type") orelse return false;
    const bare = std.mem.trim(u8, given[0 .. std.mem.indexOfScalar(u8, given, ';') orelse given.len], " ");
    return std.ascii.eqlIgnoreCase(bare, "text/event-stream");
}

/// The JSON body of `response`, read as `T`; `invalid_response`, naming `what`, where it is not.
pub fn jsonBody(comptime T: type, call: *Call, response: foundation.http.Response, what: []const u8) Error!T {
    defer response.close();
    const body = response.body.allocRemaining(call.arena, .limited(256 << 20)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return call.failWith(.transport, "The provider's answer broke off", .{}),
    };
    return http.parse(T, call, body, what);
}

/// The bytes of `response`'s body, and what they are, as its `Content-Type` says, else `default_type`.
pub fn bytesBody(call: *Call, response: foundation.http.Response, default_type: []const u8) Error!struct { media_type: []const u8, data: []const u8 } {
    defer response.close();
    const data = response.body.allocRemaining(call.arena, .limited(1 << 30)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return call.failWith(.transport, "The provider's answer broke off", .{}),
    };
    const given = response.header("content-type") orelse "";
    const bare = std.mem.trim(u8, given[0 .. std.mem.indexOfScalar(u8, given, ';') orelse given.len], " ");
    const unstated = bare.len == 0 or std.ascii.eqlIgnoreCase(bare, "application/octet-stream");
    return .{ .media_type = if (unstated) default_type else try std.ascii.allocLowerString(call.arena, bare), .data = data };
}

/// `failure` as it is, but a refusal of one of `statuses`, by which what was asked for is no longer kept, which is
/// `invalid_request`, saying `gone`.
pub fn goneAsInvalid(call: *Call, statuses: []const u16, comptime gone: []const u8, arguments: anytype) Error {
    const failure = call.failure orelse return error.Failed;
    const status = failure.status orelse return error.Failed;
    if (std.mem.indexOfScalar(u16, statuses, status) == null) return error.Failed;
    var made = try @import("../../failure.zig").Failure.format(call.arena, .invalid_request, gone, arguments);
    made.status = status;
    made.body = failure.body;
    return call.fail(made);
}
