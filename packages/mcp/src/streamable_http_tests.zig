//! The client over Streamable HTTP against the fake server as the host's HTTP: the headers a stateless request
//! carries, its stream read and closed as its cancellation, a session kept, its GET stream heard, a broken stream
//! resumed, a session that ends, a refused token, and a server out of reach.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const protocol = @import("protocol.zig");
const types = @import("types.zig");
const Client = @import("Client.zig");
const transport_ = @import("transport.zig");
const StreamableHttp = @import("streamable_http.zig").StreamableHttp;
const TestHost = @import("testing/host.zig").Host;
const server_ = @import("testing/server.zig");
const FakeServer = server_.FakeServer;
const HttpServer = @import("testing/http.zig").HttpServer;

const url = "https://mcp.example/mcp";

fn json(arena: Allocator, text: []const u8) Allocator.Error!Value {
    return std.json.parseFromSliceLeaky(Value, arena, text, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => std.debug.panic("a test's JSON does not parse: {s}", .{text}),
    };
}

const echo: server_.Tool = .{ .definition = "{\"name\":\"echo\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}}}}", .call = struct {
    fn call(given: *server_.ToolCall) server_.Error!server_.Outcome {
        try given.progress(1, 1, null);
        return .{ .result = try std.fmt.allocPrint(given.arena, "{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}]}}", .{given.arguments.object.get("text").?.string}) };
    }
}.call };

const region: server_.Tool = .{ .definition = "{\"name\":\"query\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"region\":{\"type\":\"string\",\"x-mcp-header\":\"Region\"},\"limit\":{\"type\":\"integer\",\"x-mcp-header\":\"Limit\"}}}}", .call = struct {
    fn call(_: *server_.ToolCall) server_.Error!server_.Outcome {
        return .{ .result = "{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}" };
    }
}.call };

const slow: server_.Tool = .{ .definition = "{\"name\":\"slow\",\"inputSchema\":{\"type\":\"object\"}}", .call = struct {
    fn call(given: *server_.ToolCall) server_.Error!server_.Outcome {
        try given.progress(1, null, null);
        return .waits;
    }
}.call };

const greet: server_.Tool = .{ .definition = "{\"name\":\"greet\",\"inputSchema\":{\"type\":\"object\"}}", .call = struct {
    fn call(given: *server_.ToolCall) server_.Error!server_.Outcome {
        const answer = try given.elicit("name", "{\"message\":\"Who?\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}}}}") orelse return .asked;
        return .{ .result = try std.fmt.allocPrint(given.arena, "{{\"content\":[{{\"type\":\"text\",\"text\":\"Hello, {s}\"}}]}}", .{answer.object.get("content").?.object.get("name").?.string}) };
    }
}.call };

/// A client of the fake server over HTTP, and the server, which keeps each request.
const Connected = struct { client: *Client, server: *HttpServer, fake: *FakeServer, host: *TestHost, made: Client.Connected };

fn connected(a: Allocator, options: server_.Options, extra: []const @import("foundation").http.Header, token: ?[]const u8) !Connected {
    const host = try a.create(TestHost);
    host.* = .{};
    const kept_host = try a.create(transport_.Host);
    kept_host.* = host.host();
    const fake = try a.create(FakeServer);
    fake.* = .init(a, options);
    const server = try a.create(HttpServer);
    server.* = .init(a, fake, kept_host);
    server.token = token;
    const http_transport = try StreamableHttp.init(a, kept_host, server.network(), .{ .url = url, .headers = extra });
    const made = try Client.connect(a, a, .{
        .host = host.host(),
        .client = .{ .name = "test-client", .version = "1.0.0" },
        .timeout_ms = 2000,
        .probe_timeout_ms = 500,
        .elicitation = .{ .form = true },
    }, http_transport.transport());
    if (made == .failed and token == null) std.debug.print("connect failed: {s}\n", .{try made.failed.message(a)});
    return .{ .client = if (made == .client) made.client else undefined, .server = server, .fake = fake, .host = host, .made = made };
}

const Person = struct {
    fn handler() Client.ElicitHandler {
        return .{ .context = undefined, .answer = answer };
    }

    fn answer(_: *anyopaque, arena: Allocator, _: types.ElicitRequest) Allocator.Error!types.ElicitResult {
        return .{ .accept = try json(arena, "{\"name\":\"Ada\"}") };
    }
};

test "a stateless request mirrors its version, method, name and x-mcp-header arguments into headers, without a session" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const given = try connected(a, .{ .eras = &.{.modern}, .tools = &.{ echo, region } }, &.{}, null);
    defer given.client.deinit();
    try std.testing.expectEqual(.modern, given.client.era().?);
    _ = (try given.client.allTools(a, .{})).done;
    const called = (try given.client.callTool(a, "query", try json(a, "{\"region\":\"eu west\",\"limit\":5}"), .{})).done;
    try std.testing.expectEqualStrings("ok", called.content[0].text.text);
    const last = given.server.requests.items.len - 1;
    try std.testing.expectEqualStrings(protocol.version, given.server.header(last, "mcp-protocol-version").?);
    try std.testing.expectEqualStrings("tools/call", given.server.header(last, "mcp-method").?);
    try std.testing.expectEqualStrings("query", given.server.header(last, "mcp-name").?);
    try std.testing.expectEqualStrings("eu west", given.server.header(last, "mcp-param-region").?);
    try std.testing.expectEqualStrings("5", given.server.header(last, "mcp-param-limit").?);
    try std.testing.expectEqual(null, given.server.header(last, "mcp-session-id"));
    _ = (try given.client.callTool(a, "echo", try json(a, "{\"text\":\"été\"}"), .{})).done;
}

test "a stateless request's SSE answer brings its progress, and closing its stream cancels it, with no notification" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const given = try connected(a, .{ .eras = &.{.modern}, .tools = &.{ echo, slow } }, &.{}, null);
    defer given.client.deinit();
    var count: usize = 0;
    const counted = struct {
        fn progressed(context: *anyopaque, _: types.Progress) void {
            const seen: *usize = @ptrCast(@alignCast(context));
            seen.* += 1;
        }
    }.progressed;
    const echoed = (try given.client.callTool(a, "echo", try json(a, "{\"text\":\"hi\"}"), .{ .progress = .{ .context = &count, .progressed = counted } })).done;
    try std.testing.expectEqualStrings("hi", echoed.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 1), count);
    const failed = (try given.client.callTool(a, "slow", null, .{ .timeout_ms = 1000 })).failed;
    try std.testing.expectEqual(@as(u64, 1000), failed.timeout.timeout_ms);
    try std.testing.expectEqual(@as(usize, 1), given.fake.cancelled.items.len);
    for (try given.fake.methods()) |method| try std.testing.expect(!std.mem.eql(u8, method, "notifications/cancelled"));
}

test "a session-based server is initialized after it refuses server/discover, its session kept, and its own messages heard on the GET stream" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const given = try connected(a, .{ .eras = &.{.legacy}, .tools = &.{echo} }, &.{}, null);
    defer given.client.deinit();
    try std.testing.expectEqual(.legacy, given.client.era().?);
    _ = (try given.client.callTool(a, "echo", try json(a, "{\"text\":\"hi\"}"), .{})).done;
    const last = given.server.requests.items.len - 1;
    try std.testing.expectEqualStrings("session-1", given.server.header(last, "mcp-session-id").?);
    try std.testing.expectEqual(null, try given.client.nextEvent(a, 10));
    try given.fake.setTools(&.{});
    try std.testing.expectEqual(.tools_list_changed, std.meta.activeTag((try given.client.nextEvent(a, 10)).?));
}

test "a session's broken stream is resumed from its last event id, and its question answered on the way" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const given = try connected(a, .{ .eras = &.{.legacy}, .tools = &.{ echo, greet } }, &.{}, null);
    defer given.client.deinit();
    given.server.break_after = 0;
    const echoed = (try given.client.callTool(a, "echo", try json(a, "{\"text\":\"again\"}"), .{})).done;
    try std.testing.expectEqualStrings("again", echoed.content[0].text.text);
    var resumed = false;
    for (given.server.requests.items) |request| if (@import("foundation").http.find(request.headers, "last-event-id") != null) {
        resumed = true;
    };
    try std.testing.expect(resumed);
    const greeted = (try given.client.callTool(a, "greet", null, .{ .elicit = Person.handler() })).done;
    try std.testing.expectEqualStrings("Hello, Ada", greeted.content[0].text.text);
}

test "a session-based request is cancelled with notifications/cancelled" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const given = try connected(a, .{ .eras = &.{.legacy}, .tools = &.{slow} }, &.{}, null);
    defer given.client.deinit();
    _ = (try given.client.callTool(a, "slow", null, .{ .timeout_ms = 1000 })).failed.timeout;
    try std.testing.expectEqual(@as(usize, 1), given.fake.cancelled.items.len);
}

test "the client closes when the server ends the session, and a request it answered so fails as such" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const given = try connected(a, .{ .eras = &.{.legacy}, .tools = &.{echo} }, &.{}, null);
    defer given.client.deinit();
    given.server.expireSession();
    const failed = (try given.client.callTool(a, "echo", try json(a, "{\"text\":\"hi\"}"), .{})).failed;
    try std.testing.expectEqualStrings("The MCP server ended the session", failed.session_ended);
    try std.testing.expectEqual(.closed, given.client.currentState());
}

test "a 401 says sign-in is required, with the server's challenge, and the transport adds no credentials but its own" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const refused = try connected(a, .{ .eras = &.{.modern} }, &.{}, "secret");
    const failure = refused.made.failed.unauthorized;
    try std.testing.expectEqual(@as(u16, 401), failure.status);
    try std.testing.expect(std.mem.indexOf(u8, failure.www_authenticate.?, "resource_metadata=") != null);
    const signed = try connected(a, .{ .eras = &.{.modern} }, &.{.{ .name = "authorization", .value = "Bearer secret" }}, "secret");
    defer signed.client.deinit();
    try std.testing.expectEqual(.modern, signed.client.era().?);
}

test "the client closes when the server cannot be reached" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const given = try connected(a, .{ .eras = &.{.modern}, .tools = &.{echo} }, &.{}, null);
    defer given.client.deinit();
    given.server.reachable = false;
    const failed = (try given.client.callTool(a, "echo", try json(a, "{\"text\":\"hi\"}"), .{})).failed;
    try std.testing.expect(std.mem.startsWith(u8, failed.connection_lost, "The MCP server at https://mcp.example/mcp could not be reached"));
}
