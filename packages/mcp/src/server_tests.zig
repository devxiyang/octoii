//! The server against the client, over an in-process channel on the real io: both eras, lists and calls, progress and
//! logs, the server's questions, cancellation, resources and prompts, list changes; and what it answers to messages it
//! cannot take.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const jsonrpc = @import("jsonrpc.zig");
const protocol = @import("protocol.zig");
const types = @import("types.zig");
const memory = @import("memory.zig");
const transport_ = @import("transport.zig");
const Client = @import("Client.zig");
const Server = @import("Server.zig");

/// The tools, resources and prompts the tests serve, and what the server did with them.
const Fixture = struct {
    io: std.Io,
    lock: std.Io.Mutex = .init,
    cancelled: usize = 0,
    extra_tool: bool = false,

    fn of(context: *anyopaque) *Fixture {
        return @ptrCast(@alignCast(context));
    }

    fn tools(fixture: *Fixture) Server.Tools {
        return .{ .context = fixture, .vtable = &.{ .list = listTools, .call = callTool } };
    }

    fn resources(fixture: *Fixture) Server.Resources {
        return .{ .context = fixture, .vtable = &.{ .list = listResources, .templates = listTemplates, .read = read } };
    }

    fn prompts(fixture: *Fixture) Server.Prompts {
        return .{ .context = fixture, .vtable = &.{ .list = listPrompts, .get = getPrompt } };
    }

    fn listTools(context: *anyopaque, arena: Allocator) Allocator.Error![]const types.Tool {
        const names = [_][]const u8{ "echo", "slow", "ask", "roots", "progressing" };
        var made: std.ArrayList(types.Tool) = .empty;
        for (names) |name| try made.append(arena, .{ .name = name, .inputSchema = try json(arena, "{\"type\":\"object\"}") });
        made.items[0].outputSchema = try json(arena, "{\"type\":\"object\",\"properties\":{\"echoed\":{\"type\":\"string\"}},\"required\":[\"echoed\"]}");
        if (of(context).extra_tool) try made.append(arena, .{ .name = "extra", .inputSchema = try json(arena, "{\"type\":\"object\"}") });
        return made.items;
    }

    fn callTool(context: *anyopaque, call: *Server.Call, name: []const u8, arguments: Value) Server.Error!types.CallToolResult {
        const fixture = of(context);
        const eql = std.mem.eql;
        if (eql(u8, name, "echo")) {
            const text = if (arguments.object.get("text")) |given| given.string else "";
            return .{ .content = try texts(call.arena, &.{text}), .structuredContent = try json(call.arena, try std.fmt.allocPrint(call.arena, "{{\"echoed\":\"{s}\"}}", .{text})) };
        }
        if (eql(u8, name, "slow")) {
            fixture.io.sleep(.fromSeconds(3600), .awake) catch |err| {
                fixture.lock.lockUncancelable(fixture.io);
                fixture.cancelled += 1;
                fixture.lock.unlock(fixture.io);
                return err;
            };
            return .{ .content = &.{} };
        }
        if (eql(u8, name, "ask")) {
            const schema = try json(call.arena, "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}},\"required\":[\"name\"]}");
            const first = try call.elicit("name", .{ .form = .{ .message = "Who are you?", .requestedSchema = schema } });
            const who = switch (first) {
                .accept => |content| content.?.object.get("name").?.string,
                else => return .{ .content = try texts(call.arena, &.{"declined"}) },
            };
            const second = try call.elicit("sure", .{ .form = .{ .message = "Sure?", .requestedSchema = try json(call.arena, "{\"type\":\"object\",\"properties\":{}}") } });
            return .{ .content = try texts(call.arena, &.{try std.fmt.allocPrint(call.arena, "{s}:{t}", .{ who, std.meta.activeTag(second) })}) };
        }
        if (eql(u8, name, "roots")) {
            const roots = try call.roots("roots");
            var uris: std.ArrayList(u8) = .empty;
            for (roots, 0..) |root, index| {
                if (index > 0) try uris.append(call.arena, ',');
                try uris.appendSlice(call.arena, root.uri);
            }
            return .{ .content = try texts(call.arena, &.{uris.items}) };
        }
        if (eql(u8, name, "progressing")) {
            try call.progress(1, 2, "half");
            try call.log(.debug, null, .{ .string = "hidden" });
            try call.log(.info, "fixture", .{ .string = "seen" });
            try call.progress(2, 2, null);
            return .{ .content = try texts(call.arena, &.{"finished"}) };
        }
        return call.refuse(jsonrpc.codes.invalid_params, "Unknown tool: {s}", .{name});
    }

    fn listResources(_: *anyopaque, arena: Allocator) Allocator.Error![]const types.Resource {
        const made = try arena.alloc(types.Resource, 2);
        made[0] = .{ .uri = "file:///a", .name = "a", .mimeType = "text/plain" };
        made[1] = .{ .uri = "file:///b", .name = "b" };
        return made;
    }

    fn listTemplates(_: *anyopaque, arena: Allocator) Allocator.Error![]const types.ResourceTemplate {
        const made = try arena.alloc(types.ResourceTemplate, 1);
        made[0] = .{ .uriTemplate = "file:///{name}", .name = "file" };
        return made;
    }

    fn read(_: *anyopaque, call: *Server.Call, uri: []const u8) Server.Error![]const types.ResourceContents {
        if (!std.mem.eql(u8, uri, "file:///a")) return call.refuse(Server.resource_not_found, "Resource not found: {s}", .{uri});
        const made = try call.arena.alloc(types.ResourceContents, 1);
        made[0] = .{ .text = .{ .uri = uri, .mimeType = "text/plain", .text = "alpha" } };
        return made;
    }

    fn listPrompts(_: *anyopaque, arena: Allocator) Allocator.Error![]const types.Prompt {
        const arguments = try arena.alloc(types.PromptArgument, 1);
        arguments[0] = .{ .name = "who", .required = true };
        const made = try arena.alloc(types.Prompt, 1);
        made[0] = .{ .name = "greet", .arguments = arguments };
        return made;
    }

    fn getPrompt(_: *anyopaque, call: *Server.Call, name: []const u8, arguments: ObjectMap) Server.Error!types.GetPromptResult {
        if (!std.mem.eql(u8, name, "greet")) return call.refuse(jsonrpc.codes.invalid_params, "Unknown prompt: {s}", .{name});
        const who = if (arguments.get("who")) |given| given.string else "nobody";
        const messages = try call.arena.alloc(types.PromptMessage, 1);
        messages[0] = .{ .role = .user, .content = .{ .text = .{ .text = try std.fmt.allocPrint(call.arena, "Hello, {s}.", .{who}) } } };
        return .{ .messages = messages };
    }
};

fn json(arena: Allocator, text: []const u8) Allocator.Error!Value {
    return std.json.parseFromSliceLeaky(Value, arena, text, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => std.debug.panic("a test's JSON does not parse: {s}", .{text}),
    };
}

fn texts(arena: Allocator, given: []const []const u8) Allocator.Error![]const types.ContentBlock {
    const made = try arena.alloc(types.ContentBlock, given.len);
    for (given, made) |text, *block| block.* = .{ .text = .{ .text = text } };
    return made;
}

fn textOf(content: []const types.ContentBlock) []const u8 {
    return content[0].text.text;
}

/// A server of the fixture, and a client of it over an in-process channel; the server checks its memory.
const Given = struct {
    server: *Server,
    client: *Client,
    fixture: *Fixture,

    fn deinit(given: Given) void {
        given.client.deinit();
        given.server.deinit();
    }
};

const Setup = struct {
    eras: []const protocol.Era = &.{ .modern, .legacy },
    page_size: ?usize = null,
    client: Client.Options = .{ .host = undefined, .client = .{ .name = "test-client", .version = "1.0.0" }, .timeout_ms = 5000, .probe_timeout_ms = 1000 },
};

fn connected(a: Allocator, setup: Setup) !Given {
    const host = try a.create(transport_.Host);
    host.* = .{ .io = std.testing.io };
    const fixture = try a.create(Fixture);
    fixture.* = .{ .io = std.testing.io };
    const server = try Server.init(std.testing.allocator, std.testing.io, .{
        .info = .{ .name = "fixture", .version = "2.0.0" },
        .instructions = "Serve well.",
        .tools = fixture.tools(),
        .resources = fixture.resources(),
        .prompts = fixture.prompts(),
        .eras = setup.eras,
        .page_size = setup.page_size,
    });
    errdefer server.deinit();
    const pair = try memory.Pair.init(a, host, server.memoryServer());
    var with = setup.client;
    with.host = host.*;
    const made = try Client.connect(a, a, with, pair.transport());
    return .{ .server = server, .client = made.client, .fixture = fixture };
}

const both = [_]protocol.Era{ .modern, .legacy };

test "a client of either era connects, lists the tools and calls one, its structured content checked" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for (both) |era| {
        const given = try connected(a, .{ .eras = &.{era} });
        defer given.deinit();
        const settled = given.client.server().?;
        try std.testing.expectEqual(era, settled.era);
        try std.testing.expectEqualStrings("fixture", settled.server.?.name);
        try std.testing.expectEqualStrings("Serve well.", settled.instructions.?);
        const tools = (try given.client.allTools(a, .{})).done;
        try std.testing.expectEqual(@as(usize, 5), tools.len);
        var arguments: ObjectMap = .empty;
        try arguments.put(a, "text", .{ .string = "hi" });
        const echoed = (try given.client.callTool(a, "echo", .{ .object = arguments }, .{})).done;
        try std.testing.expectEqualStrings("hi", textOf(echoed.content));
        try std.testing.expectEqualStrings("hi", echoed.structuredContent.?.object.get("echoed").?.string);
        const unknown = (try given.client.callTool(a, "nothing", null, .{})).failed;
        try std.testing.expectEqual(@as(i64, jsonrpc.codes.invalid_params), unknown.refused.code);
        if (era == .legacy) _ = (try given.client.ping(a, .{})).done;
    }
}

test "a client that speaks both eras is spoken to statelessly" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const given = try connected(arena_state.allocator(), .{});
    defer given.deinit();
    try std.testing.expectEqual(.modern, given.client.era().?);
}

test "the server pages its lists by the size it is given" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const given = try connected(a, .{ .page_size = 2 });
    defer given.deinit();
    const first = (try given.client.listTools(a, null, .{})).done;
    try std.testing.expectEqual(@as(usize, 2), first.items.len);
    try std.testing.expectEqualStrings("2", first.nextCursor.?);
    try std.testing.expectEqual(@as(usize, 5), (try given.client.allTools(a, .{})).done.len);
    const refused = (try given.client.listTools(a, "x", .{})).failed;
    try std.testing.expectEqual(@as(i64, jsonrpc.codes.invalid_params), refused.refused.code);
}

test "progress goes to the request that asked for it, and log messages at the level the client set" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for (both) |era| {
        const given = try connected(a, .{ .eras = &.{era} });
        defer given.deinit();
        _ = (try given.client.setLoggingLevel(a, .info)).done;
        var seen: std.ArrayList(types.Progress) = .empty;
        defer seen.deinit(std.testing.allocator);
        const Seen = struct {
            fn progressed(context: *anyopaque, progress: types.Progress) void {
                const list: *std.ArrayList(types.Progress) = @ptrCast(@alignCast(context));
                list.append(std.testing.allocator, progress) catch {};
            }
        };
        const done = (try given.client.callTool(a, "progressing", null, .{ .progress = .{ .context = &seen, .progressed = Seen.progressed } })).done;
        try std.testing.expectEqualStrings("finished", textOf(done.content));
        try std.testing.expectEqual(@as(usize, 2), seen.items.len);
        try std.testing.expectEqualStrings("half", seen.items[0].message.?);
        const event = (try given.client.nextEvent(a, 1000)).?;
        try std.testing.expectEqual(.info, event.log.level);
        try std.testing.expectEqualStrings("fixture", event.log.logger.?);
        try std.testing.expectEqual(null, try given.client.nextEvent(a, 0));
    }
}

/// Answers the fixture's questions: a name, then yes.
const Answers = struct {
    fn answer(_: *anyopaque, arena: Allocator, request: types.ElicitRequest) Allocator.Error!types.ElicitResult {
        if (std.mem.eql(u8, request.form.message, "Sure?")) return .{ .accept = .{ .object = .empty } };
        return .{ .accept = try json(arena, "{\"name\":\"Ada\"}") };
    }
};

test "the server asks the client its questions in either era, the call run again with each answer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for (both) |era| {
        var setup: Setup = .{ .eras = &.{era} };
        setup.client.elicitation = .{ .form = true, .handler = .{ .context = undefined, .answer = Answers.answer } };
        const given = try connected(a, setup);
        defer given.deinit();
        const answered = (try given.client.callTool(a, "ask", null, .{})).done;
        try std.testing.expectEqualStrings("Ada:accept", textOf(answered.content));
    }
}

test "a stateless client's questions handed back are answered past the request, with the state the server kept" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var setup: Setup = .{ .eras = &.{.modern} };
    setup.client.elicitation = .{ .form = true };
    const given = try connected(a, setup);
    defer given.deinit();
    const first = (try given.client.callTool(a, "ask", null, .{ .hand_back_input = true })).failed.input_required.input;
    const name = try a.alloc(types.KeyedAnswer, 1);
    name[0] = .{ .key = "name", .answer = .{ .accept = try json(a, "{\"name\":\"Lin\"}") } };
    const second = (try given.client.callTool(a, "ask", null, .{ .hand_back_input = true, .answered = .{ .required = first, .answers = name } })).failed.input_required.input;
    try std.testing.expectEqualStrings("sure", second.requests[0].key);
    const sure = try a.alloc(types.KeyedAnswer, 1);
    sure[0] = .{ .key = "sure", .answer = .decline };
    const done = (try given.client.callTool(a, "ask", null, .{ .answered = .{ .required = second, .answers = sure } })).done;
    try std.testing.expectEqualStrings("Lin:decline", textOf(done.content));
}

test "a question the client does not offer is refused, and its roots are asked where it does" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for (both) |era| {
        var setup: Setup = .{ .eras = &.{era} };
        setup.client.roots = &.{ .{ .uri = "file:///one" }, .{ .uri = "file:///two" } };
        const given = try connected(a, setup);
        defer given.deinit();
        const refused = (try given.client.callTool(a, "ask", null, .{})).failed;
        const code: i64 = if (era == .modern) protocol.codes.missing_required_client_capability else jsonrpc.codes.invalid_params;
        try std.testing.expectEqual(code, refused.refused.code);
        const roots = (try given.client.callTool(a, "roots", null, .{})).done;
        try std.testing.expectEqualStrings("file:///one,file:///two", textOf(roots.content));
    }
}

test "a request the client cancels has its task cancelled, and the server serves the next" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for (both) |era| {
        const given = try connected(a, .{ .eras = &.{era} });
        defer given.deinit();
        const failed = (try given.client.callTool(a, "slow", null, .{ .timeout_ms = 50 })).failed;
        try std.testing.expectEqual(@as(u64, 50), failed.timeout.timeout_ms);
        _ = (try given.client.allTools(a, .{})).done;
        try std.testing.expectEqual(@as(usize, 1), given.fixture.cancelled);
    }
}

test "resources are listed and read, prompts listed and got, in either era" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for (both) |era| {
        const given = try connected(a, .{ .eras = &.{era} });
        defer given.deinit();
        const resources = (try given.client.listResources(a, null, .{})).done;
        try std.testing.expectEqual(@as(usize, 2), resources.items.len);
        try std.testing.expectEqualStrings("text/plain", resources.items[0].mimeType.?);
        const templates = (try given.client.listResourceTemplates(a, null, .{})).done;
        try std.testing.expectEqualStrings("file:///{name}", templates.items[0].uriTemplate);
        const contents = (try given.client.readResource(a, "file:///a", .{})).done;
        try std.testing.expectEqualStrings("alpha", contents.contents[0].text.text);
        const missing = (try given.client.readResource(a, "file:///z", .{})).failed;
        try std.testing.expectEqual(@as(i64, Server.resource_not_found), missing.refused.code);
        const prompts = (try given.client.listPrompts(a, null, .{})).done;
        try std.testing.expectEqualStrings("who", prompts.items[0].arguments.?[0].name);
        const prompt = (try given.client.getPrompt(a, "greet", &.{.{ "who", "Ada" }}, .{})).done;
        try std.testing.expectEqualStrings("Hello, Ada.", prompt.messages[0].content.text.text);
    }
}

test "a list's change reaches a stateless subscription that asked for it, and a session" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for (both) |era| {
        const given = try connected(a, .{ .eras = &.{era} });
        defer given.deinit();
        const subscription = (try given.client.listen(a, .{ .toolsListChanged = true, .resourceSubscriptions = &.{"file:///a"} })).done;
        defer subscription.close();
        try std.testing.expect(subscription.acknowledged.toolsListChanged);
        try std.testing.expectEqual(@as(usize, 0), subscription.acknowledged.resourceSubscriptions.len);
        given.fixture.extra_tool = true;
        given.server.toolsChanged();
        try std.testing.expectEqual(.tools_list_changed, std.meta.activeTag((try subscription.next(a, 1000)).?));
        try std.testing.expectEqual(@as(usize, 6), (try given.client.allTools(a, .{})).done.len);
    }
}

/// What the server sent, as JSON text.
const Sent = struct {
    messages: std.ArrayList([]const u8) = .empty,

    fn peer(sent: *Sent) Server.Peer {
        return .{ .context = sent, .send = send };
    }

    fn send(context: *anyopaque, message: []const u8) void {
        const sent: *Sent = @ptrCast(@alignCast(context));
        sent.messages.append(std.testing.allocator, std.testing.allocator.dupe(u8, message) catch return) catch {};
    }

    fn deinit(sent: *Sent) void {
        for (sent.messages.items) |message| std.testing.allocator.free(message);
        sent.messages.deinit(std.testing.allocator);
    }

    /// The last message's error code.
    fn lastCode(sent: *const Sent, arena: Allocator) !i64 {
        const message = try jsonrpc.parseOne(arena, sent.messages.items[sent.messages.items.len - 1]);
        return message.failure.@"error".code;
    }
};

test "the server refuses what is not JSON-RPC, a version it does not speak, and a request before a session opens" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var fixture: Fixture = .{ .io = std.testing.io };
    const server = try Server.init(std.testing.allocator, std.testing.io, .{ .info = .{ .name = "raw", .version = "1" }, .tools = fixture.tools() });
    defer server.deinit();
    var sent: Sent = .{};
    defer sent.deinit();
    server.handle(sent.peer(), "{not json");
    try std.testing.expectEqual(@as(i64, jsonrpc.codes.parse_error), try sent.lastCode(a));
    server.handle(sent.peer(), "{\"jsonrpc\":\"2.0\"}");
    try std.testing.expectEqual(@as(i64, jsonrpc.codes.invalid_request), try sent.lastCode(a));
    server.handle(sent.peer(), "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"1999-01-01\"}}}");
    const refused = try jsonrpc.parseOne(a, sent.messages.items[2]);
    try std.testing.expectEqual(@as(i64, protocol.codes.unsupported_protocol_version), refused.failure.@"error".code);
    const supported = refused.failure.@"error".data.?.object.get("supported").?.array.items;
    try std.testing.expectEqualStrings(protocol.version, supported[0].string);
    try std.testing.expectEqual(@as(usize, 1 + protocol.legacy_versions.len), supported.len);
    server.handle(sent.peer(), "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}");
    try std.testing.expectEqual(@as(i64, jsonrpc.codes.method_not_found), try sent.lastCode(a));
    server.handle(sent.peer(), "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"prompts/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"}}}");
    try std.testing.expectEqual(@as(i64, jsonrpc.codes.method_not_found), try sent.lastCode(a));
}
