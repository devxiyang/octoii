//! The client against the fake server over an in-process channel: connecting in either era, listing and calling,
//! progress and logs, time, the server's questions, resources, prompts and completion, and the server going away.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const protocol = @import("protocol.zig");
const types = @import("types.zig");
const memory = @import("memory.zig");
const Client = @import("Client.zig");
const TestHost = @import("testing/host.zig").Host;
const server_ = @import("testing/server.zig");
const FakeServer = server_.FakeServer;
const ToolCall = server_.ToolCall;

const client_info: types.Implementation = .{ .name = "test-client", .version = "1.0.0" };

/// `text`, JSON the test wrote, in `arena`.
fn json(arena: Allocator, text: []const u8) Allocator.Error!Value {
    return std.json.parseFromSliceLeaky(Value, arena, text, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => std.debug.panic("a test's JSON does not parse: {s}", .{text}),
    };
}

fn result(text: []const u8) server_.Outcome {
    return .{ .result = text };
}

const echo: server_.Tool = .{
    .definition =
    \\{"name":"echo","description":"Echoes text.","inputSchema":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]},
    \\ "outputSchema":{"type":"object","properties":{"echoed":{"type":"string"}},"required":["echoed"]}}
    ,
    .call = struct {
        fn call(given: *ToolCall) server_.Error!server_.Outcome {
            const text = given.arguments.object.get("text").?.string;
            return result(try std.fmt.allocPrint(given.arena, "{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}],\"structuredContent\":{{\"echoed\":\"{s}\"}}}}", .{ text, text }));
        }
    }.call,
};

const fail: server_.Tool = .{
    .definition = "{\"name\":\"fail\",\"inputSchema\":{\"type\":\"object\"}}",
    .call = struct {
        fn call(_: *ToolCall) server_.Error!server_.Outcome {
            return result("{\"content\":[{\"type\":\"text\",\"text\":\"It broke.\"}],\"isError\":true}");
        }
    }.call,
};

const wrong_shape: server_.Tool = .{
    .definition = "{\"name\":\"wrong\",\"inputSchema\":{\"type\":\"object\"},\"outputSchema\":{\"type\":\"object\",\"properties\":{\"n\":{\"type\":\"number\"}},\"required\":[\"n\"]}}",
    .call = struct {
        fn call(_: *ToolCall) server_.Error!server_.Outcome {
            return result("{\"content\":[],\"structuredContent\":{\"n\":\"one\"}}");
        }
    }.call,
};

const slow: server_.Tool = .{
    .definition = "{\"name\":\"slow\",\"inputSchema\":{\"type\":\"object\"}}",
    .call = struct {
        fn call(given: *ToolCall) server_.Error!server_.Outcome {
            try given.progress(1, 3, "one");
            try given.progress(2, 3, "two");
            return .waits;
        }
    }.call,
};

const progressing: server_.Tool = .{
    .definition = "{\"name\":\"progressing\",\"inputSchema\":{\"type\":\"object\"}}",
    .call = struct {
        fn call(given: *ToolCall) server_.Error!server_.Outcome {
            try given.progress(1, 2, "half");
            try given.log(.info, try json(given.arena, "{\"step\":\"done\"}"));
            try given.log(.debug, .{ .string = "hidden" });
            try given.progress(2, 2, null);
            return result("{\"content\":[{\"type\":\"text\",\"text\":\"finished\"}]}");
        }
    }.call,
};

const greet: server_.Tool = .{
    .definition = "{\"name\":\"greet\",\"inputSchema\":{\"type\":\"object\"}}",
    .call = struct {
        fn call(given: *ToolCall) server_.Error!server_.Outcome {
            const answer = try given.elicit("name",
                \\{"mode":"form","message":"Who are you?","requestedSchema":{"type":"object","properties":{"name":{"type":"string","minLength":1}},"required":["name"]}}
            ) orelse return .asked;
            const action = answer.object.get("action").?.string;
            const name = if (std.mem.eql(u8, action, "accept")) answer.object.get("content").?.object.get("name").?.string else action;
            return result(try std.fmt.allocPrint(given.arena, "{{\"content\":[{{\"type\":\"text\",\"text\":\"Hello, {s}\"}}]}}", .{name}));
        }
    }.call,
};

const list_roots: server_.Tool = .{
    .definition = "{\"name\":\"roots\",\"inputSchema\":{\"type\":\"object\"}}",
    .call = struct {
        fn call(given: *ToolCall) server_.Error!server_.Outcome {
            const answer = try given.roots("roots") orelse return .asked;
            var uris: std.ArrayList(u8) = .empty;
            for (answer.object.get("roots").?.array.items, 0..) |root, index| {
                if (index > 0) try uris.append(given.arena, ',');
                try uris.appendSlice(given.arena, root.object.get("uri").?.string);
            }
            return result(try std.fmt.allocPrint(given.arena, "{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}]}}", .{uris.items}));
        }
    }.call,
};

const sample: server_.Tool = .{
    .definition = "{\"name\":\"sample\",\"inputSchema\":{\"type\":\"object\"}}",
    .call = struct {
        fn call(given: *ToolCall) server_.Error!server_.Outcome {
            _ = try given.sample("model") orelse return .asked;
            return result("{\"content\":[]}");
        }
    }.call,
};

/// A person who answers each form with `name`, and each link by visiting it.
const Person = struct {
    name: []const u8 = "Ada",
    asked: usize = 0,

    fn handler(person: *Person) Client.ElicitHandler {
        return .{ .context = person, .answer = answer };
    }

    fn answer(context: *anyopaque, arena: Allocator, request: types.ElicitRequest) Allocator.Error!types.ElicitResult {
        const person: *Person = @ptrCast(@alignCast(context));
        person.asked += 1;
        return switch (request) {
            .url => .{ .accept = null },
            .form => .{ .accept = try json(arena, try std.fmt.allocPrint(arena, "{{\"name\":\"{s}\"}}", .{person.name})) },
        };
    }
};

/// A client of a fake server, both in the test's arena.
const Connected = struct { fake: *FakeServer, client: *Client, pair: *memory.Pair, host: *TestHost, reports: *std.ArrayList([]const u8) };

/// A client of a fake server, connecting: the client, or the failure it could not connect with.
const Connecting = struct { made: Client.Connected, fake: *FakeServer, pair: *memory.Pair, host: *TestHost, reports: *std.ArrayList([]const u8) };

fn connecting(a: Allocator, options: server_.Options, given: Client.Options) !Connecting {
    const host = try a.create(TestHost);
    host.* = .{};
    const fake = try a.create(FakeServer);
    fake.* = .init(a, options);
    const kept_host = try a.create(@import("transport.zig").Host);
    kept_host.* = host.host();
    const pair = try memory.Pair.init(a, kept_host, fake.server());
    const reports = try a.create(std.ArrayList([]const u8));
    reports.* = .empty;
    var with = given;
    with.host = host.host();
    with.client = client_info;
    with.reporter = .{ .context = reports, .report = struct {
        fn report(context: *anyopaque, problem: []const u8) void {
            const kept: *std.ArrayList([]const u8) = @ptrCast(@alignCast(context));
            kept.append(std.testing.allocator, problem) catch {};
        }
    }.report };
    return .{ .made = try Client.connect(a, a, with, pair.transport()), .fake = fake, .pair = pair, .host = host, .reports = reports };
}

fn connected(a: Allocator, options: server_.Options, given: Client.Options) !Connected {
    const made = try connecting(a, options, given);
    return .{ .client = made.made.client, .fake = made.fake, .pair = made.pair, .host = made.host, .reports = made.reports };
}

fn defaults() Client.Options {
    return .{ .host = undefined, .client = client_info, .timeout_ms = 2000, .probe_timeout_ms = 500 };
}

fn textOf(content: []const types.ContentBlock) []const u8 {
    return content[0].text.text;
}

test "the client speaks the stateless protocol to a server that does, after server/discover" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const given = try connected(a, .{ .eras = &.{.modern}, .instructions = "Use it well.", .name = "modern" }, defaults());
    defer given.client.deinit();
    const server = given.client.server().?;
    try std.testing.expectEqual(.modern, server.era);
    try std.testing.expectEqualStrings(protocol.version, server.version);
    try std.testing.expectEqualStrings("modern", server.server.?.name);
    try std.testing.expectEqualStrings("Use it well.", server.instructions.?);
    const methods = try given.fake.methods();
    try std.testing.expectEqual(@as(usize, 1), methods.len);
    try std.testing.expectEqualStrings("server/discover", methods[0]);
}

test "the client falls back to initialize for a server of the session-based protocol, and prefers the stateless one where both are spoken" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const legacy = try connected(a, .{ .eras = &.{.legacy} }, defaults());
    defer legacy.client.deinit();
    try std.testing.expectEqual(.legacy, legacy.client.era().?);
    try std.testing.expectEqualStrings(protocol.legacy_versions[0], legacy.client.server().?.version);
    const methods = try legacy.fake.methods();
    try std.testing.expectEqualStrings("initialize", methods[1]);
    try std.testing.expectEqualStrings("notifications/initialized", methods[2]);
    const both = try connected(a, .{}, defaults());
    defer both.client.deinit();
    try std.testing.expectEqual(.modern, both.client.era().?);
    const unknown_modern = try connected(a, .{ .versions = &.{"2099-01-01"} }, defaults());
    defer unknown_modern.client.deinit();
    try std.testing.expectEqual(.legacy, unknown_modern.client.era().?);
}

test "the client refuses a server that speaks no version it knows" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const refused = (try connecting(a, .{ .eras = &.{.modern}, .versions = &.{"2099-01-01"} }, defaults())).made.failed;
    try std.testing.expectEqualStrings("The MCP server speaks 2099-01-01, none of which this client speaks", refused.protocol);
}

test "the client never declares sampling, and declares only the features it offers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var with = defaults();
    with.elicitation = .{ .form = true };
    with.roots = &.{.{ .uri = "file:///work" }};
    const given = try connected(a, .{ .eras = &.{.modern} }, with);
    defer given.client.deinit();
    try std.testing.expectEqualStrings("{\"elicitation\":{\"form\":{}},\"roots\":{}}", try @import("foundation").json.encode(a, given.fake.session.capabilities));
}

test "the client lists tools page by page, and calls one with its structured content checked against its output schema" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for ([_]protocol.Era{ .modern, .legacy }) |era| {
        const given = try connected(a, .{ .eras = &.{era}, .tools = &.{ echo, fail, wrong_shape }, .page_size = 1 }, defaults());
        defer given.client.deinit();
        const tools = (try given.client.allTools(a, .{})).done;
        try std.testing.expectEqual(@as(usize, 3), tools.len);
        try std.testing.expectEqualStrings("wrong", tools[2].name);
        const echoed = (try given.client.callTool(a, "echo", try std.json.parseFromSliceLeaky(Value, a, "{\"text\":\"hi\"}", .{}), .{})).done;
        try std.testing.expectEqualStrings("hi", textOf(echoed.content));
        const failed = (try given.client.callTool(a, "fail", null, .{})).done;
        try std.testing.expectEqual(true, failed.isError.?);
        const wrong = (try given.client.callTool(a, "wrong", null, .{})).failed;
        try std.testing.expect(std.mem.startsWith(u8, wrong.protocol, "The structured content of the MCP tool wrong does not match its output schema: /n must be number"));
    }
}

test "the client passes progress and log messages on, at the level it set" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for ([_]protocol.Era{ .modern, .legacy }) |era| {
        const given = try connected(a, .{ .eras = &.{era}, .tools = &.{progressing} }, defaults());
        defer given.client.deinit();
        _ = (try given.client.setLoggingLevel(a, .info)).done;
        var seen: std.ArrayList(types.Progress) = .empty;
        const Seen = struct {
            fn progressed(context: *anyopaque, progress: types.Progress) void {
                const list: *std.ArrayList(types.Progress) = @ptrCast(@alignCast(context));
                list.append(std.testing.allocator, progress) catch {};
            }
        };
        defer seen.deinit(std.testing.allocator);
        const done = (try given.client.callTool(a, "progressing", null, .{ .progress = .{ .context = &seen, .progressed = Seen.progressed } })).done;
        try std.testing.expectEqualStrings("finished", textOf(done.content));
        try std.testing.expectEqual(@as(usize, 2), seen.items.len);
        try std.testing.expectEqualStrings("half", seen.items[0].message.?);
        const event = (try given.client.nextEvent(a, 0)).?;
        try std.testing.expectEqual(.info, event.log.level);
        try std.testing.expectEqual(null, try given.client.nextEvent(a, 0));
    }
}

test "the client times a request out and cancels it, a progress notification starting the time again where asked" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for ([_]protocol.Era{ .modern, .legacy }) |era| {
        const given = try connected(a, .{ .eras = &.{era}, .tools = &.{slow} }, defaults());
        defer given.client.deinit();
        const started = given.host.clock_ms;
        const failed = (try given.client.callTool(a, "slow", null, .{ .timeout_ms = 1000 })).failed;
        try std.testing.expectEqual(@as(u64, 1000), failed.timeout.timeout_ms);
        try std.testing.expectEqual(started + 1000, given.host.clock_ms);
        try std.testing.expectEqual(@as(usize, 1), given.fake.cancelled.items.len);
    }
}

test "the client answers a form elicitation through the request's handler, checking the content against the form" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for ([_]protocol.Era{ .modern, .legacy }) |era| {
        var with = defaults();
        with.elicitation = .{ .form = true, .url = true };
        const given = try connected(a, .{ .eras = &.{era}, .tools = &.{greet} }, with);
        defer given.client.deinit();
        var person: Person = .{};
        const greeted = (try given.client.callTool(a, "greet", null, .{ .elicit = person.handler() })).done;
        try std.testing.expectEqualStrings("Hello, Ada", textOf(greeted.content));
        try std.testing.expectEqual(@as(usize, 1), person.asked);
        const declined = (try given.client.callTool(a, "greet", null, .{})).done;
        try std.testing.expectEqualStrings("Hello, decline", textOf(declined.content));
        var nobody: Person = .{ .name = "" };
        const refused = try given.client.callTool(a, "greet", null, .{ .elicit = nobody.handler() });
        switch (era) {
            .modern => try std.testing.expect(std.mem.startsWith(u8, refused.failed.invalid_answer, "The answer to the elicitation does not match its form")),
            .legacy => try std.testing.expect(std.mem.indexOf(u8, refused.failed.refused.message, "does not match its form") != null),
        }
    }
}

test "the client gives its roots when asked, and never samples" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for ([_]protocol.Era{ .modern, .legacy }) |era| {
        var with = defaults();
        with.roots = &.{ .{ .uri = "file:///one" }, .{ .uri = "file:///two" } };
        const given = try connected(a, .{ .eras = &.{era}, .tools = &.{ list_roots, sample } }, with);
        defer given.client.deinit();
        const roots = (try given.client.callTool(a, "roots", null, .{})).done;
        try std.testing.expectEqualStrings("file:///one,file:///two", textOf(roots.content));
        const sampled = (try given.client.callTool(a, "sample", null, .{})).failed;
        try std.testing.expect(sampled.refused.code == protocol.codes.missing_required_client_capability or sampled.refused.code == -32601);
    }
}

test "the client hands a stateless server's questions back, and the request sent again with the answers goes on" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var with = defaults();
    with.elicitation = .{ .form = true };
    const given = try connected(a, .{ .eras = &.{.modern}, .tools = &.{greet} }, with);
    defer given.client.deinit();
    const handed = (try given.client.callTool(a, "greet", null, .{ .hand_back_input = true })).failed.input_required;
    try std.testing.expectEqualStrings("tools/call", handed.method);
    try std.testing.expectEqualStrings("name", handed.input.requests[0].key);
    const content = try std.json.parseFromSliceLeaky(Value, a, "{\"name\":\"Grace\"}", .{});
    const answered = (try given.client.callTool(a, "greet", null, .{ .answered = .{ .required = handed.input, .answers = &.{.{ .key = "name", .answer = .{ .accept = content } }} } })).done;
    try std.testing.expectEqualStrings("Hello, Grace", textOf(answered.content));
}

test "the client reads resources and templates, gets prompts and completes arguments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const prompt: server_.Prompt = .{ .definition = "{\"name\":\"review\",\"arguments\":[{\"name\":\"code\",\"required\":true}]}", .get = struct {
        fn get(arena: Allocator, arguments: std.json.ObjectMap) Allocator.Error![]const u8 {
            return std.fmt.allocPrint(arena, "{{\"messages\":[{{\"role\":\"user\",\"content\":{{\"type\":\"text\",\"text\":\"Review {s}\"}}}}]}}", .{arguments.get("code").?.string});
        }
    }.get };
    const options: server_.Options = .{
        .resources = &.{.{ .definition = "{\"uri\":\"file:///a.txt\",\"name\":\"a\"}", .contents = "[{\"uri\":\"file:///a.txt\",\"text\":\"A\"}]" }},
        .resource_templates = &.{"{\"uriTemplate\":\"file:///{name}\",\"name\":\"files\"}"},
        .prompts = &.{prompt},
        .complete = struct {
            fn complete(_: []const u8, value: []const u8) []const []const u8 {
                return if (std.mem.eql(u8, value, "py")) &.{ "python", "pytorch" } else &.{};
            }
        }.complete,
    };
    for ([_]protocol.Era{ .modern, .legacy }) |era| {
        var with_era = options;
        with_era.eras = &.{era};
        const given = try connected(a, with_era, defaults());
        defer given.client.deinit();
        try std.testing.expectEqualStrings("a", (try given.client.listResources(a, null, .{})).done.items[0].name);
        try std.testing.expectEqualStrings("A", (try given.client.readResource(a, "file:///a.txt", .{})).done.contents[0].text.text);
        try std.testing.expectEqualStrings("files", (try given.client.listResourceTemplates(a, null, .{})).done.items[0].name);
        try std.testing.expectEqualStrings("review", (try given.client.listPrompts(a, null, .{})).done.items[0].name);
        const got = (try given.client.getPrompt(a, "review", &.{.{ "code", "main.zig" }}, .{})).done;
        try std.testing.expectEqualStrings("Review main.zig", got.messages[0].content.text.text);
        const completed = (try given.client.complete(a, .{ .prompt = .{ .name = "review" } }, .{ "code", "py" }, &.{}, .{})).done;
        try std.testing.expectEqual(@as(usize, 2), completed.values.len);
        try std.testing.expectEqual(-32602, (try given.client.readResource(a, "file:///none", .{})).failed.refused.code);
    }
}

test "the client leaves out a tool whose x-mcp-header annotations are invalid, and reports it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const invalid: server_.Tool = .{ .definition = "{\"name\":\"bad\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"number\",\"x-mcp-header\":\"A\"}}}}", .call = fail.call };
    const given = try connected(a, .{ .tools = &.{ echo, invalid } }, defaults());
    defer given.client.deinit();
    defer given.reports.deinit(std.testing.allocator);
    const tools = (try given.client.allTools(a, .{})).done;
    try std.testing.expectEqual(@as(usize, 1), tools.len);
    try std.testing.expectEqualStrings("The MCP tool bad is left out: x-mcp-header A is on a, which is not a string, integer or boolean", given.reports.items[0]);
}

test "the client pings a session-based server, and a stateless one has no ping" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const legacy = try connected(a, .{ .eras = &.{.legacy} }, defaults());
    defer legacy.client.deinit();
    _ = (try legacy.client.ping(a, .{})).done;
    const modern = try connected(a, .{ .eras = &.{.modern} }, defaults());
    defer modern.client.deinit();
    try std.testing.expect(std.mem.startsWith(u8, (try modern.client.ping(a, .{})).failed.protocol, "ping is not part of the stateless protocol"));
}

test "the client fails what waits once the server goes away, and is closed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const leaving: server_.Tool = .{ .definition = "{\"name\":\"leave\",\"inputSchema\":{\"type\":\"object\"}}", .call = struct {
        fn call(given: *ToolCall) server_.Error!server_.Outcome {
            given.sink.close();
            return .waits;
        }
    }.call };
    const given = try connected(a, .{ .tools = &.{leaving} }, defaults());
    defer given.client.deinit();
    const failed = (try given.client.callTool(a, "leave", null, .{})).failed;
    try std.testing.expectEqualStrings("The MCP connection closed: the server closed the in-process channel", failed.connection_lost);
    try std.testing.expectEqual(.closed, given.client.currentState());
}

test "the client listens for list changes and resource updates, in either era" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for ([_]protocol.Era{ .modern, .legacy }) |era| {
        const resource: server_.Resource = .{ .definition = "{\"uri\":\"file:///a\",\"name\":\"a\"}", .contents = "[]" };
        const given = try connected(a, .{ .eras = &.{era}, .tools = &.{echo}, .resources = &.{resource} }, defaults());
        defer given.client.deinit();
        const subscription = (try given.client.listen(a, .{ .toolsListChanged = true, .resourceSubscriptions = &.{"file:///a"} })).done;
        defer subscription.close();
        try std.testing.expect(subscription.acknowledged.toolsListChanged);
        try std.testing.expectEqualStrings("file:///a", subscription.acknowledged.resourceSubscriptions[0]);
        try given.fake.setTools(&.{ echo, fail });
        try std.testing.expectEqual(.tools_list_changed, std.meta.activeTag((try subscription.next(a, 0)).?));
        try given.fake.resourceUpdated("file:///a");
        try std.testing.expectEqualStrings("file:///a", (try subscription.next(a, 0)).?.resource_updated);
        try std.testing.expectEqual(null, try subscription.next(a, 0));
        try std.testing.expectEqual(null, subscription.ended);
    }
}

test "the client learns that a stateless server ended a subscription, and closes one it no longer wants" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const given = try connected(a, .{ .eras = &.{.modern} }, defaults());
    defer given.client.deinit();
    const ended = (try given.client.listen(a, .{ .toolsListChanged = true })).done;
    defer ended.close();
    try given.fake.endSubscriptions();
    try std.testing.expectEqual(null, try ended.next(a, 0));
    try std.testing.expectEqual(.server, ended.ended.?);
    const closed = (try given.client.listen(a, .{ .toolsListChanged = true })).done;
    closed.close();
    try std.testing.expectEqual(@as(usize, 1), given.fake.cancelled.items.len);
}
