//! The text kind over Chat Completions, which Z.ai and the servers on this machine share. A request goes to its
//! address as its messages, its functions and the settings its dialect makes of the request, with the request's
//! provider options set over them, as a stream; its chunks come back as the vocabulary's events, and its failures are
//! classified as its dialect reads them. Servers that follow OpenAI's reference classify theirs as this file does.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const Request = vocabulary.ResponsesRequest;
const Event = vocabulary.ResponseStreamEvent;
const ReasoningEffort = vocabulary.items.ReasoningEffort;
const seam = @import("../driver.zig");
const Call = seam.Call;
const failure_ = @import("../failure.zig");
const Error = failure_.Error;
const Kind = failure_.Kind;
const Model = @import("../catalogue/model.zig").Model;
const check = @import("../text/check.zig");
const http = @import("http.zig");
const json = @import("json.zig");
const responses = @import("responses.zig");
pub const messages = @import("chat_completions/messages.zig");
pub const stream = @import("chat_completions/stream.zig");

/// What makes one provider's Chat Completions its own: where it is, how it is asked, and how it answers and fails.
/// `Settings` is the type of the fields its settings make of a request.
pub fn Dialect(comptime Settings: type) type {
    return struct {
        /// The address its API's paths follow where its provider gives none; null, a provider must give one.
        base_url: ?[]const u8,
        /// Where `/chat/completions` is under the address.
        path: []const u8 = "/chat/completions",
        messages: messages.Options,
        /// The authorization a request goes with; null for none.
        authorization: *const fn (call: *Call) Error!?[]const u8,
        /// The request's settings as its provider takes them, the effort in effect at its end among them; `Failed` for
        /// one it does not take.
        settings: *const fn (call: *Call, model: *const Model, request: *const Request, effort: ?ReasoningEffort) Error!Settings,
        /// What the body of a refusal before the stream says of the failure.
        details: http.DetailsOf,
        /// Finish reasons of the provider's own, beyond Chat Completions' own.
        endings: []const stream.NamedEnding = &.{},
        stream_failure: stream.StreamFailureOf,
    };
}

/// The text call of a provider of Chat Completions, as `dialect` speaks it.
pub fn text(comptime Settings: type, comptime dialect: Dialect(Settings)) seam.TextCall {
    return struct {
        fn call(given: *Call, model: *const Model, request: *const Request) Error!seam.TextSource {
            return send(Settings, dialect, given, model, request);
        }
    }.call;
}

/// The address of the provider's `/chat/completions`.
pub fn url(comptime Settings: type, dialect: Dialect(Settings), call: *Call) Error![]const u8 {
    const base = call.provider.settings.base_url orelse dialect.base_url orelse
        return call.failWith(.invalid_request, "A provider of a Chat Completions server names where the server is, its base_url", .{});
    return std.fmt.allocPrint(call.arena, "{s}{s}", .{ base, dialect.path });
}

/// The body `request` goes to `dialect`'s provider with for `model`: the model by its id, its messages and functions
/// with the changes of its items folded, its settings, its provider options and a stream.
pub fn body(comptime Settings: type, dialect: Dialect(Settings), call: *Call, model: *const Model, request: *const Request) Error![]const u8 {
    const folded = try responses.foldEffortChanges(call.arena, try responses.foldToolChanges(call.arena, request.*));
    // A model that does not reason was prepared with no effort.
    const effort = if (folded.reasoning) |reasoning| reasoning.effort else null;
    const base = .{
        .model = model.id,
        .messages = try messages.messages(call, &folded, dialect.messages),
        .tools = try messages.tools(call, &folded),
    };
    const settings = try dialect.settings(call, model, &folded, effort);
    const options = try json.ownOptions(call.arena, request, call.provider.driver.id);
    return foundation.json.encode(call.arena, foundation.json.merged(.{ base, settings, options, .{ .stream = true } }));
}

fn send(comptime Settings: type, comptime dialect: Dialect(Settings), call: *Call, model: *const Model, request: *const Request) Error!seam.TextSource {
    try check.parts(call, model, request, &.{});
    const address = try url(Settings, dialect, call);
    const authorization = try dialect.authorization(call);
    const sent = try body(Settings, dialect, call, model, request);
    var headers: std.ArrayList(foundation.http.Header) = .empty;
    if (authorization) |given| try headers.append(call.arena, .{ .name = "authorization", .value = given });
    try headers.appendSlice(call.arena, &.{ .{ .name = "accept", .value = "text/event-stream" }, .{ .name = "content-type", .value = "application/json" } });
    const response = try http.send(call, .{ .method = .POST, .url = address, .headers = headers.items, .body = sent });
    if (response.status < 200 or response.status >= 300) return call.fail(try http.failureOf(call, response, dialect.details));
    const source = try call.arena.create(Source);
    source.* = .{ .events = .init(call, response), .translator = .{ .call = call, .endings = dialect.endings, .stream_failure = dialect.stream_failure } };
    return .{ .context = source, .vtable = &.{ .next = Source.next, .close = Source.close } };
}

/// The events of one response, its chunks read until `[DONE]`, then its end.
const Source = struct {
    events: http.Events,
    translator: stream.Translator,
    ended: bool = false,
    pending: std.ArrayList(Event) = .empty,
    head: usize = 0,

    fn next(context: *anyopaque) Error!?Event {
        const source: *Source = @ptrCast(@alignCast(context));
        const arena = source.translator.call.arena;
        while (source.head == source.pending.items.len) {
            if (source.ended) return null;
            source.pending.clearRetainingCapacity();
            source.head = 0;
            const event = try source.events.next();
            const data = if (event) |given| std.mem.trim(u8, given.data, " \t\r\n") else "[DONE]";
            if (std.mem.eql(u8, data, "[DONE]")) {
                source.ended = true;
                try source.translator.end(&source.pending);
                continue;
            }
            // The data lives until the next read; what is translated from it keeps its own copy.
            if (data.len > 0) try source.translator.chunk(try arena.dupe(u8, data), &source.pending);
        }
        defer source.head += 1;
        return source.pending.items[source.head];
    }

    fn close(context: *anyopaque) void {
        const source: *Source = @ptrCast(@alignCast(context));
        source.events.close();
    }
};

/// The authorization of a server that takes an API key or none: the key where the host's credentials hold one,
/// none where they hold none; `auth` where they hold a sign-in.
pub fn serverAuthorization(call: *Call) Error!?[]const u8 {
    return switch (try call.credential() orelse return null) {
        .none => null,
        .api_key => |key| try std.fmt.allocPrint(call.arena, "Bearer {s}", .{key}),
        .oauth => call.failWith(.auth, "The provider {s} takes an API key or none, and the host's credentials hold a sign-in for it", .{call.provider.id}),
    };
}

/// The failure kind of each code and type of OpenAI's reference, and of the servers that follow it, that says one.
const kinds_of_codes = std.StaticStringMap(Kind).initComptime(.{
    .{ "context_length_exceeded", .context_overflow }, .{ "exceed_context_size_error", .context_overflow },
    .{ "rate_limit_exceeded", .rate_limit },           .{ "insufficient_quota", .quota },
    .{ "invalid_api_key", .auth },                     .{ "authentication_error", .auth },
    .{ "permission_error", .forbidden },               .{ "server_error", .server },
});

/// A server's error: its kind where its code, type or message says one, its code and its message.
const ServerError = struct { kind: ?Kind = null, code: ?[]const u8 = null, message: ?[]const u8 = null };

/// What a server's error says, as an object of OpenAI's shape or as its message alone; null for neither.
fn serverError(arena: Allocator, given: std.json.Value) Allocator.Error!?ServerError {
    switch (given) {
        .string => |message| return .{ .kind = try kindOfMessage(arena, message), .message = message },
        .object => |object| {
            const code: ?[]const u8 = if (object.get("code")) |value| (if (value == .string) value.string else null) else null;
            const kind_name = json.textOf(given, "type");
            const message = json.textOf(given, "message");
            const named = code orelse kind_name;
            const kind = (if (named) |each| kinds_of_codes.get(each) else null) orelse
                (if (kind_name) |each| kinds_of_codes.get(each) else null) orelse
                try kindOfMessage(arena, message orelse "");
            return .{ .kind = kind, .code = named, .message = message };
        },
        else => return null,
    }
}

/// `context_overflow` where `message` speaks of a context too long, in the words servers put it.
fn kindOfMessage(arena: Allocator, message: []const u8) Allocator.Error!?Kind {
    const lowered = try std.ascii.allocLowerString(arena, message);
    const said = [_][]const u8{ "context length", "context size", "context window", "maximum context", "too many tokens", "prompt is too long" };
    for (said) |words| if (std.mem.indexOf(u8, lowered, words) != null) return .context_overflow;
    return null;
}

/// What a server's body says of a refusal before the stream: its error, or a message alone, as some servers send it.
pub fn serverDetails(arena: Allocator, given: []const u8) ?http.Details {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, given, .{}) catch return null;
    if (parsed != .object) return null;
    const raised = parsed.object.get("error") orelse parsed.object.get("message") orelse return null;
    if (raised == .null) return null;
    const said = (serverError(arena, raised) catch return null) orelse return null;
    return .{ .kind = said.kind, .code = said.code, .message = said.message };
}

/// The failure an error in a server's stream stands for: by its code, else `server`.
pub fn serverStreamFailure(arena: Allocator, given: std.json.Value) Allocator.Error!stream.StreamFailure {
    const said = try serverError(arena, given) orelse ServerError{};
    const kind = said.kind orelse .server;
    return .{
        .octoii = .{ .kind = kind, .retryable = failure_.retryableKind(kind) },
        .code = said.code orelse @tagName(kind),
        .message = said.message orelse "The provider's stream failed without saying why",
    };
}

test "a server's failure is classified by its code, then its type, then its words" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const coded = serverDetails(a, "{\"error\":{\"message\":\"Bad key\",\"type\":\"invalid_request_error\",\"code\":\"invalid_api_key\"}}").?;
    try std.testing.expectEqual(Kind.auth, coded.kind.?);
    try std.testing.expectEqualStrings("invalid_api_key", coded.code.?);
    const worded = serverDetails(a, "{\"message\":\"the request exceeds the available context size\"}").?;
    try std.testing.expectEqual(Kind.context_overflow, worded.kind.?);
    const typed = serverDetails(a, "{\"error\":{\"message\":\"slow down\",\"type\":\"rate_limit_exceeded\",\"code\":429}}").?;
    try std.testing.expectEqual(Kind.rate_limit, typed.kind.?);
    try std.testing.expectEqualStrings("rate_limit_exceeded", typed.code.?);
    const silent = try serverStreamFailure(a, .null);
    try std.testing.expectEqualStrings("server", silent.code);
}
