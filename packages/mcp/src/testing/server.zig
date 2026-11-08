//! A fake MCP server for tests: tools, resources, prompts, completion and logging, speaking the stateless protocol, the
//! session-based one, or both, over an in-process channel. A tool that asks the client something is run again with
//! the answer: a stateless request comes back with it, as `input_required` asks; a session's answer to the server's own
//! request reruns the call. Everything it keeps lives in the test's arena.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const foundation = @import("foundation");
const jsonrpc = @import("../jsonrpc.zig");
const protocol = @import("../protocol.zig");
const types = @import("../types.zig");
const memory = @import("../memory.zig");

/// What a fake tool's call reaches: its arguments, the answers to its questions so far, and the client.
pub const ToolCall = struct {
    arena: Allocator,
    arguments: Value,
    session: *Session,
    sink: Channel,
    progress_token: ?Value,
    answers: ObjectMap,
    /// The question it asked, where it asked one: its key, method and params.
    asked: ?Asked = null,

    pub const Asked = struct { key: []const u8, method: []const u8, params: Value };

    /// Sends progress, where the request asked for it.
    pub fn progress(call: *ToolCall, done: f64, total: ?f64, message: ?[]const u8) Allocator.Error!void {
        const token = call.progress_token orelse return;
        var params: ObjectMap = .empty;
        try params.put(call.arena, "progressToken", token);
        try params.put(call.arena, "progress", .{ .float = done });
        if (total) |given| try params.put(call.arena, "total", .{ .float = given });
        if (message) |given| try params.put(call.arena, "message", .{ .string = given });
        try notify(call.arena, call.sink, "notifications/progress", .{ .object = params });
    }

    /// Sends a log message, where the client's level lets it through.
    pub fn log(call: *ToolCall, level: types.LoggingLevel, data: Value) Allocator.Error!void {
        const floor = call.session.log_level orelse return;
        if (@backingInt(level) < @backingInt(floor)) return;
        var params: ObjectMap = .empty;
        try params.put(call.arena, "level", .{ .string = @tagName(level) });
        try params.put(call.arena, "data", data);
        try notify(call.arena, call.sink, "notifications/message", .{ .object = params });
    }

    /// The client's answer to the question `key`, an elicitation of `request`; null where it is asked now, and the call
    /// is to return `.asked`. `MissingCapability` where a stateless client does not offer the elicitation's mode.
    pub fn elicit(call: *ToolCall, key: []const u8, request: []const u8) Error!?Value {
        const params = try parsed(call.arena, request);
        const mode = if (params.object.get("mode")) |given| given.string else "form";
        return call.ask(key, "elicitation/create", params, try std.fmt.allocPrint(call.arena, "elicitation.{s}", .{mode}));
    }

    /// The client's roots, under `key`; null where they are asked for now.
    pub fn roots(call: *ToolCall, key: []const u8) Error!?Value {
        return call.ask(key, "roots/list", .{ .object = .empty }, "roots");
    }

    /// Asks the client to sample, which a client that does not offer it refuses.
    pub fn sample(call: *ToolCall, key: []const u8) Error!?Value {
        var params: ObjectMap = .empty;
        try params.put(call.arena, "messages", .{ .array = .init(call.arena) });
        try params.put(call.arena, "maxTokens", .{ .integer = 10 });
        return call.ask(key, "sampling/createMessage", .{ .object = params }, "sampling");
    }

    fn ask(call: *ToolCall, key: []const u8, method: []const u8, params: Value, capability: []const u8) Error!?Value {
        if (call.answers.get(key)) |answer| return answer;
        if (call.session.era == .modern and !hasCapability(call.session.capabilities, capability)) return error.MissingCapability;
        call.asked = .{ .key = key, .method = method, .params = params };
        return null;
    }
};

pub const Error = Allocator.Error || error{MissingCapability};

/// Where the server's messages go: for one request, or apart from any — the in-process channel, or an HTTP stream.
pub const Channel = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (context: *anyopaque, message: []const u8) void,
        /// Closes the channel from the server's side, as a process that exits.
        close: *const fn (context: *anyopaque) void,
    };

    /// Sends `message`, JSON text.
    pub fn send(channel: Channel, message: []const u8) void {
        channel.vtable.send(channel.context, message);
    }

    pub fn close(channel: Channel) void {
        channel.vtable.close(channel.context);
    }

    /// The in-process channel `sink` sends on.
    fn ofSink(pair: *memory.Pair) Channel {
        return .{ .context = pair, .vtable = &.{ .send = sinkSend, .close = sinkClose } };
    }

    fn sinkSend(context: *anyopaque, message: []const u8) void {
        (memory.Sink{ .pair = @ptrCast(@alignCast(context)) }).send(message);
    }

    fn sinkClose(context: *anyopaque) void {
        (memory.Sink{ .pair = @ptrCast(@alignCast(context)) }).close();
    }
};

/// What a fake tool's call comes to: its result as JSON, a question asked through the call, or a wait until it is
/// cancelled.
pub const Outcome = union(enum) {
    result: []const u8,
    asked,
    waits,
};

pub const Tool = struct {
    /// The tool's definition, as JSON.
    definition: []const u8,
    call: *const fn (call: *ToolCall) Error!Outcome,
};

pub const Resource = struct { definition: []const u8, contents: []const u8 };
pub const Prompt = struct { definition: []const u8, get: *const fn (arena: Allocator, arguments: ObjectMap) Allocator.Error![]const u8 };

pub const Options = struct {
    eras: []const protocol.Era = &.{ .modern, .legacy },
    /// The stateless versions it supports.
    versions: []const []const u8 = &protocol.modern_versions,
    name: []const u8 = "fake",
    instructions: ?[]const u8 = null,
    tools: []const Tool = &.{},
    resources: ?[]const Resource = null,
    resource_templates: ?[]const []const u8 = null,
    prompts: ?[]const Prompt = null,
    complete: ?*const fn (argument: []const u8, value: []const u8) []const []const u8 = null,
    /// How many items a list page holds; none, all.
    page_size: ?usize = null,
};

/// A call that waits: for its question's answer, or until it is cancelled.
const Running = struct {
    id: jsonrpc.Id,
    /// Where its messages go.
    channel: Channel,
    tool: ?*const Tool,
    arguments: Value,
    progress_token: ?Value,
    answers: ObjectMap,
    /// The id of the server's request asking its question, and the key its answer goes under.
    ask_id: ?[]const u8 = null,
    key: ?[]const u8 = null,
};

/// What the server keeps of one client.
pub const Session = struct {
    era: ?protocol.Era = null,
    version: ?[]const u8 = null,
    initialized: bool = false,
    log_level: ?types.LoggingLevel = null,
    capabilities: Value = .{ .object = .empty },
    subscriptions: std.ArrayList([]const u8) = .empty,
    running: std.ArrayList(Running) = .empty,
    next_ask: usize = 1,
    ended: bool = false,
};

pub const FakeServer = struct {
    arena: Allocator,
    options: Options,
    tools: []const Tool,
    session: Session = .{},
    /// Every message received, as JSON text, in order.
    received: std.ArrayList([]const u8) = .empty,
    /// The ids of requests cancelled while they ran.
    cancelled: std.ArrayList(jsonrpc.Id) = .empty,
    sink: ?Channel = null,
    /// The stateless subscriptions open: their request's id and what they acknowledged.
    listeners: std.ArrayList(Listener) = .empty,

    const Listener = struct { id: jsonrpc.Id, filter: types.SubscriptionFilter };

    pub fn init(arena: Allocator, options: Options) FakeServer {
        return .{ .arena = arena, .options = options, .tools = options.tools };
    }

    pub fn server(fake: *FakeServer) memory.Server {
        return .{ .context = fake, .vtable = &.{ .handle = handle, .closed = closed } };
    }

    /// The methods of the messages received, in order.
    pub fn methods(fake: *const FakeServer) Allocator.Error![]const []const u8 {
        var found: std.ArrayList([]const u8) = .empty;
        for (fake.received.items) |text| {
            const message = jsonrpc.parseOne(fake.arena, text) catch continue;
            switch (message) {
                .request => |request| try found.append(fake.arena, request.method),
                .notification => |notification| try found.append(fake.arena, notification.method),
                else => {},
            }
        }
        return found.items;
    }

    /// Replaces the tools and tells the clients that listen for it.
    pub fn setTools(fake: *FakeServer, tools: []const Tool) Allocator.Error!void {
        fake.tools = tools;
        const sink = fake.sink orelse return;
        if (fake.session.era == .legacy) return notify(fake.arena, sink, "notifications/tools/list_changed", null);
        for (fake.listeners.items) |listener| if (listener.filter.toolsListChanged) {
            try notify(fake.arena, sink, "notifications/tools/list_changed", try subscribed(fake.arena, null, listener.id));
        };
    }

    /// Tells the clients subscribed to a resource that it changed.
    pub fn resourceUpdated(fake: *FakeServer, uri: []const u8) Allocator.Error!void {
        const sink = fake.sink orelse return;
        var params: ObjectMap = .empty;
        try params.put(fake.arena, "uri", .{ .string = uri });
        if (fake.session.era == .legacy) {
            for (fake.session.subscriptions.items) |each| if (std.mem.eql(u8, each, uri)) return notify(fake.arena, sink, "notifications/resources/updated", .{ .object = params });
            return;
        }
        for (fake.listeners.items) |listener| for (listener.filter.resourceSubscriptions) |each| if (std.mem.eql(u8, each, uri)) {
            try notify(fake.arena, sink, "notifications/resources/updated", try subscribed(fake.arena, .{ .object = try params.clone(fake.arena) }, listener.id));
        };
    }

    /// Ends every stateless subscription gracefully, as a server shutting down does.
    pub fn endSubscriptions(fake: *FakeServer) Allocator.Error!void {
        const sink = fake.sink orelse return;
        for (fake.listeners.items) |listener| {
            var result: ObjectMap = .empty;
            try result.put(fake.arena, "resultType", .{ .string = "complete" });
            try send(fake.arena, sink, .{ .result = .{ .id = listener.id, .result = (try subscribed(fake.arena, .{ .object = result }, listener.id)).? } });
        }
        fake.listeners.clearRetainingCapacity();
    }

    fn of(context: *anyopaque) *FakeServer {
        return @ptrCast(@alignCast(context));
    }

    fn closed(context: *anyopaque) void {
        of(context).session.ended = true;
    }

    fn handle(context: *anyopaque, sink: memory.Sink, text: []const u8) void {
        const fake = of(context);
        const channel = Channel.ofSink(sink.pair);
        fake.sink = channel;
        fake.handled(channel, text) catch {};
    }

    /// Takes `text`, a message, its answers going on `channel`.
    pub fn handleOn(fake: *FakeServer, channel: Channel, text: []const u8) void {
        fake.handled(channel, text) catch {};
    }

    /// Cancels the call `id` that waits, as a stateless server does whose stream for it closed.
    pub fn abort(fake: *FakeServer, id: jsonrpc.Id) Allocator.Error!void {
        for (fake.session.running.items, 0..) |running, index| if (running.id.eql(id)) {
            _ = fake.session.running.orderedRemove(index);
            return fake.cancelled.append(fake.arena, id);
        };
        for (fake.listeners.items, 0..) |listener, index| if (listener.id.eql(id)) {
            _ = fake.listeners.orderedRemove(index);
            return fake.cancelled.append(fake.arena, id);
        };
    }

    fn handled(fake: *FakeServer, sink: Channel, text: []const u8) Allocator.Error!void {
        try fake.received.append(fake.arena, try fake.arena.dupe(u8, text));
        const message = jsonrpc.parseOne(fake.arena, text) catch return;
        switch (message) {
            .result => |result| try fake.answered(sink, result.id, result.result),
            .failure => |failed| try fake.refusedAnswer(sink, failed),
            .notification => |notification| try fake.notified(sink, notification),
            .request => |request| try fake.requested(sink, request),
        }
    }

    fn notified(fake: *FakeServer, sink: Channel, notification: jsonrpc.Notification) Allocator.Error!void {
        if (std.mem.eql(u8, notification.method, "notifications/initialized")) fake.session.initialized = true;
        if (!std.mem.eql(u8, notification.method, "notifications/cancelled")) return;
        const params = notification.params orelse return;
        const id = jsonrpc.Id.of(params.object.get("requestId") orelse return) orelse return;
        for (fake.listeners.items, 0..) |listener, index| if (listener.id.eql(id)) {
            _ = fake.listeners.orderedRemove(index);
            try fake.cancelled.append(fake.arena, id);
            return;
        };
        for (fake.session.running.items, 0..) |running, index| if (running.id.eql(id)) {
            _ = fake.session.running.orderedRemove(index);
            try fake.cancelled.append(fake.arena, id);
            if (running.ask_id) |ask| {
                var cancel: ObjectMap = .empty;
                try cancel.put(fake.arena, "requestId", .{ .string = ask });
                try notify(fake.arena, sink, "notifications/cancelled", .{ .object = cancel });
            }
            return;
        };
    }

    /// A session-based client's answer to the server's question: the call that asked it runs again with it.
    fn answered(fake: *FakeServer, sink: Channel, id: jsonrpc.Id, result: Value) Allocator.Error!void {
        for (fake.session.running.items, 0..) |running, index| {
            const ask = running.ask_id orelse continue;
            if (!id.eql(.{ .string = ask })) continue;
            var resumed = fake.session.running.orderedRemove(index);
            try resumed.answers.put(fake.arena, resumed.key.?, result);
            _ = sink;
            return fake.run(resumed.channel, resumed);
        }
    }

    /// A session-based client's refusal of the server's question: the call that asked it fails with it.
    fn refusedAnswer(fake: *FakeServer, sink: Channel, failed: jsonrpc.Failure) Allocator.Error!void {
        const id = failed.id orelse return;
        for (fake.session.running.items, 0..) |running, index| {
            const ask = running.ask_id orelse continue;
            if (!id.eql(.{ .string = ask })) continue;
            const refused = fake.session.running.orderedRemove(index);
            _ = sink;
            return send(fake.arena, refused.channel, .{ .failure = .{ .id = refused.id, .@"error" = failed.@"error" } });
        }
    }

    fn requested(fake: *FakeServer, sink: Channel, request: jsonrpc.Request) Allocator.Error!void {
        const reply = fake.dispatch(sink, request) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Answered => return,
        };
        if (reply) |result| try send(fake.arena, sink, .{ .result = .{ .id = request.id, .result = result } });
    }

    /// The result of a request; null where it waits; `Refused` where its error was sent.
    fn dispatch(fake: *FakeServer, sink: Channel, request: jsonrpc.Request) DispatchError!?Value {
        const params = paramsOf(request);
        const modern = modernVersion(params);
        if (modern != null and fake.speaks(.modern)) return fake.modernRequest(sink, request, modern.?);
        if (std.mem.eql(u8, request.method, "initialize") and fake.speaks(.legacy)) return try fake.initialized(params);
        if (fake.session.era != .legacy) return fake.refuse(sink, request.id, jsonrpc.codes.method_not_found, "Method not found: {s}", .{request.method}, null);
        return fake.legacyRequest(sink, request);
    }

    const DispatchError = Allocator.Error || error{Answered};

    fn speaks(fake: *const FakeServer, era: protocol.Era) bool {
        return std.mem.indexOfScalar(protocol.Era, fake.options.eras, era) != null;
    }

    fn refuse(fake: *FakeServer, sink: Channel, id: jsonrpc.Id, code: i64, comptime text: []const u8, arguments: anytype, data: ?Value) DispatchError {
        const message = try std.fmt.allocPrint(fake.arena, text, arguments);
        try send(fake.arena, sink, .{ .failure = .{ .id = id, .@"error" = .{ .code = code, .message = message, .data = data } } });
        return error.Answered;
    }

    fn modernRequest(fake: *FakeServer, sink: Channel, request: jsonrpc.Request, version: []const u8) DispatchError!?Value {
        for (fake.options.versions) |each| {
            if (std.mem.eql(u8, each, version)) break;
        } else {
            var data: ObjectMap = .empty;
            var supported = std.json.Array.init(fake.arena);
            for (fake.options.versions) |each| try supported.append(.{ .string = each });
            if (fake.speaks(.legacy)) for (protocol.legacy_versions) |each| try supported.append(.{ .string = each });
            try data.put(fake.arena, "supported", .{ .array = supported });
            try data.put(fake.arena, "requested", .{ .string = version });
            return fake.refuse(sink, request.id, protocol.codes.unsupported_protocol_version, "Unsupported protocol version", .{}, .{ .object = data });
        }
        const meta = paramsOf(request).get("_meta").?.object;
        fake.session.era = .modern;
        fake.session.capabilities = meta.get(protocol.meta.client_capabilities) orelse .{ .object = .empty };
        fake.session.log_level = if (meta.get(protocol.meta.log_level)) |level| std.meta.stringToEnum(types.LoggingLevel, level.string) else null;
        if (std.mem.eql(u8, request.method, "server/discover")) return try fake.discovered();
        if (std.mem.eql(u8, request.method, "subscriptions/listen")) return fake.listened(sink, request);
        const result = try fake.common(sink, request) orelse return null;
        var complete = result.object;
        try complete.put(fake.arena, "resultType", .{ .string = "complete" });
        return .{ .object = complete };
    }

    /// A stateless subscription: acknowledged with what the server will send, and kept open.
    fn listened(fake: *FakeServer, sink: Channel, request: jsonrpc.Request) DispatchError!?Value {
        const wanted = paramsOf(request).get("notifications");
        const filter = try @import("../results.zig").subscriptionFilter(fake.arena, wanted);
        const has_resources = fake.options.resources != null or fake.options.resource_templates != null;
        const acknowledged: types.SubscriptionFilter = .{
            .toolsListChanged = filter.toolsListChanged,
            .promptsListChanged = filter.promptsListChanged and fake.options.prompts != null,
            .resourcesListChanged = filter.resourcesListChanged and has_resources,
            .resourceSubscriptions = if (has_resources) filter.resourceSubscriptions else &.{},
        };
        try fake.listeners.append(fake.arena, .{ .id = request.id, .filter = acknowledged });
        var params: ObjectMap = .empty;
        try params.put(fake.arena, "notifications", try foundation.json.toValue(fake.arena, acknowledged));
        try notify(fake.arena, sink, "notifications/subscriptions/acknowledged", try subscribed(fake.arena, .{ .object = params }, request.id));
        return null;
    }

    fn discovered(fake: *FakeServer) Allocator.Error!Value {
        var result: ObjectMap = .empty;
        try result.put(fake.arena, "resultType", .{ .string = "complete" });
        try result.put(fake.arena, "supportedVersions", try foundation.json.toValue(fake.arena, fake.options.versions));
        try result.put(fake.arena, "capabilities", try fake.capabilities());
        var meta: ObjectMap = .empty;
        try meta.put(fake.arena, protocol.meta.server_info, try foundation.json.toValue(fake.arena, types.Implementation{ .name = fake.options.name, .version = "1.0.0" }));
        try result.put(fake.arena, "_meta", .{ .object = meta });
        if (fake.options.instructions) |text| try result.put(fake.arena, "instructions", .{ .string = text });
        return .{ .object = result };
    }

    fn initialized(fake: *FakeServer, params: ObjectMap) Allocator.Error!Value {
        const offered = if (params.get("protocolVersion")) |given| (if (given == .string) given.string else "") else "";
        fake.session.era = .legacy;
        fake.session.version = if (protocol.isLegacyVersion(offered)) offered else protocol.legacy_versions[0];
        fake.session.capabilities = params.get("capabilities") orelse .{ .object = .empty };
        var result: ObjectMap = .empty;
        try result.put(fake.arena, "protocolVersion", .{ .string = fake.session.version.? });
        try result.put(fake.arena, "capabilities", try fake.capabilities());
        try result.put(fake.arena, "serverInfo", try foundation.json.toValue(fake.arena, types.Implementation{ .name = fake.options.name, .version = "1.0.0" }));
        if (fake.options.instructions) |text| try result.put(fake.arena, "instructions", .{ .string = text });
        return .{ .object = result };
    }

    fn legacyRequest(fake: *FakeServer, sink: Channel, request: jsonrpc.Request) DispatchError!?Value {
        const eql = std.mem.eql;
        const params = paramsOf(request);
        if (eql(u8, request.method, "ping")) return .{ .object = .empty };
        if (eql(u8, request.method, "logging/setLevel")) {
            const level = if (params.get("level")) |given| (if (given == .string) std.meta.stringToEnum(types.LoggingLevel, given.string) else null) else null;
            fake.session.log_level = level orelse return fake.refuse(sink, request.id, jsonrpc.codes.invalid_params, "Unknown log level", .{}, null);
            return .{ .object = .empty };
        }
        if (eql(u8, request.method, "resources/subscribe") or eql(u8, request.method, "resources/unsubscribe")) {
            const uri = params.get("uri") orelse return fake.refuse(sink, request.id, jsonrpc.codes.invalid_params, "No uri", .{}, null);
            if (eql(u8, request.method, "resources/subscribe")) try fake.session.subscriptions.append(fake.arena, uri.string);
            return .{ .object = .empty };
        }
        return fake.common(sink, request);
    }

    /// The methods both protocols have.
    fn common(fake: *FakeServer, sink: Channel, request: jsonrpc.Request) DispatchError!?Value {
        const eql = std.mem.eql;
        const params = paramsOf(request);
        const method = request.method;
        if (eql(u8, method, "tools/list")) return try fake.page(params, "tools", try definitions(fake.arena, fake.tools));
        if (eql(u8, method, "tools/call")) return fake.callTool(sink, request);
        if (eql(u8, method, "resources/list")) return try fake.page(params, "resources", try resourceDefinitions(fake.arena, fake.options.resources orelse &.{}));
        if (eql(u8, method, "resources/templates/list")) return try fake.page(params, "resourceTemplates", try parsedAll(fake.arena, fake.options.resource_templates orelse &.{}));
        if (eql(u8, method, "resources/read")) return fake.readResource(sink, request);
        if (eql(u8, method, "prompts/list")) return try fake.page(params, "prompts", try promptDefinitions(fake.arena, fake.options.prompts orelse &.{}));
        if (eql(u8, method, "prompts/get")) return fake.getPrompt(sink, request);
        if (eql(u8, method, "completion/complete")) return try fake.completed(params);
        return fake.refuse(sink, request.id, jsonrpc.codes.method_not_found, "Method not found: {s}", .{method}, null);
    }

    fn callTool(fake: *FakeServer, sink: Channel, request: jsonrpc.Request) DispatchError!?Value {
        const params = paramsOf(request);
        const name = if (params.get("name")) |given| (if (given == .string) given.string else "") else "";
        const tool = for (fake.tools) |*each| {
            const definition = try parsed(fake.arena, each.definition);
            if (std.mem.eql(u8, definition.object.get("name").?.string, name)) break each;
        } else return fake.refuse(sink, request.id, jsonrpc.codes.invalid_params, "Unknown tool: {s}", .{name}, null);
        const meta = if (params.get("_meta")) |given| given.object else ObjectMap.empty;
        var running: Running = .{ .id = request.id, .channel = sink, .tool = tool, .arguments = params.get("arguments") orelse .{ .object = .empty }, .progress_token = meta.get("progressToken"), .answers = try fake.givenAnswers(params) };
        _ = &running;
        try fake.run(sink, running);
        return error.Answered;
    }

    /// Runs a call: its result sent, its question asked, or its wait kept.
    fn run(fake: *FakeServer, sink: Channel, given: Running) Allocator.Error!void {
        var running = given;
        var call: ToolCall = .{ .arena = fake.arena, .arguments = running.arguments, .session = &fake.session, .sink = sink, .progress_token = running.progress_token, .answers = running.answers };
        const outcome = running.tool.?.call(&call) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MissingCapability => {
                var data: ObjectMap = .empty;
                try data.put(fake.arena, "requiredCapabilities", .{ .object = .empty });
                return send(fake.arena, sink, .{ .failure = .{ .id = running.id, .@"error" = .{ .code = protocol.codes.missing_required_client_capability, .message = "Missing client capability", .data = .{ .object = data } } } });
            },
        };
        switch (outcome) {
            .result => |text| {
                var result = (try parsed(fake.arena, text)).object;
                if (fake.session.era == .modern) try result.put(fake.arena, "resultType", .{ .string = "complete" });
                try send(fake.arena, sink, .{ .result = .{ .id = running.id, .result = .{ .object = result } } });
            },
            .waits => try fake.session.running.append(fake.arena, running),
            .asked => try fake.asked(sink, &running, call.asked.?),
        }
    }

    /// Asks the client the call's question: a stateless request answered `input_required`, a session's sent the
    /// server's own request.
    fn asked(fake: *FakeServer, sink: Channel, running: *Running, question: ToolCall.Asked) Allocator.Error!void {
        if (fake.session.era == .modern) {
            var request: ObjectMap = .empty;
            try request.put(fake.arena, "method", .{ .string = question.method });
            try request.put(fake.arena, "params", question.params);
            var requests: ObjectMap = .empty;
            try requests.put(fake.arena, question.key, .{ .object = request });
            var result: ObjectMap = .empty;
            try result.put(fake.arena, "resultType", .{ .string = "input_required" });
            try result.put(fake.arena, "inputRequests", .{ .object = requests });
            try result.put(fake.arena, "requestState", .{ .string = try foundation.json.encode(fake.arena, Value{ .object = running.answers }) });
            return send(fake.arena, sink, .{ .result = .{ .id = running.id, .result = .{ .object = result } } });
        }
        const id = try std.fmt.allocPrint(fake.arena, "ask-{d}", .{fake.session.next_ask});
        fake.session.next_ask += 1;
        running.ask_id = id;
        running.key = question.key;
        try fake.session.running.append(fake.arena, running.*);
        try send(fake.arena, sink, .{ .request = .{ .id = .{ .string = id }, .method = question.method, .params = question.params } });
    }

    /// The answers a stateless request brings: those its `requestState` keeps, and its `inputResponses`.
    fn givenAnswers(fake: *FakeServer, params: ObjectMap) Allocator.Error!ObjectMap {
        var answers: ObjectMap = .empty;
        if (params.get("requestState")) |state| if (state == .string) {
            const kept = std.json.parseFromSliceLeaky(Value, fake.arena, state.string, .{}) catch Value{ .object = .empty };
            if (kept == .object) answers = try kept.object.clone(fake.arena);
        };
        if (params.get("inputResponses")) |responses| if (responses == .object) {
            var it = responses.object.iterator();
            while (it.next()) |entry| try answers.put(fake.arena, entry.key_ptr.*, entry.value_ptr.*);
        };
        return answers;
    }

    fn readResource(fake: *FakeServer, sink: Channel, request: jsonrpc.Request) DispatchError!?Value {
        const uri = paramsOf(request).get("uri") orelse Value{ .string = "" };
        for (fake.options.resources orelse &.{}) |resource| {
            const definition = try parsed(fake.arena, resource.definition);
            if (!std.mem.eql(u8, definition.object.get("uri").?.string, uri.string)) continue;
            var result: ObjectMap = .empty;
            try result.put(fake.arena, "contents", try parsed(fake.arena, resource.contents));
            return .{ .object = result };
        }
        return fake.refuse(sink, request.id, jsonrpc.codes.invalid_params, "Resource not found: {s}", .{uri.string}, null);
    }

    fn getPrompt(fake: *FakeServer, sink: Channel, request: jsonrpc.Request) DispatchError!?Value {
        const params = paramsOf(request);
        const name = params.get("name") orelse Value{ .string = "" };
        for (fake.options.prompts orelse &.{}) |prompt| {
            const definition = try parsed(fake.arena, prompt.definition);
            if (!std.mem.eql(u8, definition.object.get("name").?.string, name.string)) continue;
            const arguments = if (params.get("arguments")) |given| given.object else ObjectMap.empty;
            return try parsed(fake.arena, try prompt.get(fake.arena, arguments));
        }
        return fake.refuse(sink, request.id, jsonrpc.codes.invalid_params, "Unknown prompt: {s}", .{name.string}, null);
    }

    fn completed(fake: *FakeServer, params: ObjectMap) Allocator.Error!Value {
        const argument = if (params.get("argument")) |given| given.object else ObjectMap.empty;
        const name = if (argument.get("name")) |given| given.string else "";
        const value = if (argument.get("value")) |given| given.string else "";
        const values = if (fake.options.complete) |complete| complete(name, value) else &.{};
        var completion: ObjectMap = .empty;
        try completion.put(fake.arena, "values", try foundation.json.toValue(fake.arena, values[0..@min(values.len, 100)]));
        try completion.put(fake.arena, "total", .{ .integer = @intCast(values.len) });
        try completion.put(fake.arena, "hasMore", .{ .bool = values.len > 100 });
        var result: ObjectMap = .empty;
        try result.put(fake.arena, "completion", .{ .object = completion });
        return .{ .object = result };
    }

    fn capabilities(fake: *FakeServer) Allocator.Error!Value {
        var made: ObjectMap = .empty;
        try made.put(fake.arena, "tools", try parsed(fake.arena, "{\"listChanged\":true}"));
        if (fake.options.resources != null or fake.options.resource_templates != null) try made.put(fake.arena, "resources", try parsed(fake.arena, "{\"subscribe\":true,\"listChanged\":true}"));
        if (fake.options.prompts != null) try made.put(fake.arena, "prompts", try parsed(fake.arena, "{\"listChanged\":true}"));
        if (fake.options.complete != null) try made.put(fake.arena, "completions", .{ .object = .empty });
        try made.put(fake.arena, "logging", .{ .object = .empty });
        return .{ .object = made };
    }

    fn page(fake: *FakeServer, params: ObjectMap, field: []const u8, items: []const Value) Allocator.Error!Value {
        const size = fake.options.page_size orelse items.len;
        const start = if (params.get("cursor")) |cursor| std.fmt.parseInt(usize, cursor.string, 10) catch 0 else 0;
        const end = @min(start + size, items.len);
        var listed = std.json.Array.init(fake.arena);
        try listed.appendSlice(items[@min(start, items.len)..end]);
        var result: ObjectMap = .empty;
        try result.put(fake.arena, field, .{ .array = listed });
        if (end < items.len) try result.put(fake.arena, "nextCursor", .{ .string = try std.fmt.allocPrint(fake.arena, "{d}", .{end}) });
        return .{ .object = result };
    }
};

fn definitions(arena: Allocator, tools: []const Tool) Allocator.Error![]const Value {
    const made = try arena.alloc(Value, tools.len);
    for (tools, made) |tool, *value| value.* = try parsed(arena, tool.definition);
    return made;
}

fn resourceDefinitions(arena: Allocator, resources: []const Resource) Allocator.Error![]const Value {
    const made = try arena.alloc(Value, resources.len);
    for (resources, made) |resource, *value| value.* = try parsed(arena, resource.definition);
    return made;
}

fn promptDefinitions(arena: Allocator, prompts: []const Prompt) Allocator.Error![]const Value {
    const made = try arena.alloc(Value, prompts.len);
    for (prompts, made) |prompt, *value| value.* = try parsed(arena, prompt.definition);
    return made;
}

fn parsedAll(arena: Allocator, texts: []const []const u8) Allocator.Error![]const Value {
    const made = try arena.alloc(Value, texts.len);
    for (texts, made) |text, *value| value.* = try parsed(arena, text);
    return made;
}

/// `text`, JSON the test wrote; what it holds is the test's.
fn parsed(arena: Allocator, text: []const u8) Allocator.Error!Value {
    return std.json.parseFromSliceLeaky(Value, arena, text, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => std.debug.panic("a fake server's JSON does not parse: {s}", .{text}),
    };
}

fn paramsOf(request: jsonrpc.Request) ObjectMap {
    const params = request.params orelse return .empty;
    return if (params == .object) params.object else .empty;
}

/// The stateless version a request names in its metadata.
fn modernVersion(params: ObjectMap) ?[]const u8 {
    const meta = params.get("_meta") orelse return null;
    if (meta != .object) return null;
    const version = meta.object.get(protocol.meta.protocol_version) orelse return null;
    return if (version == .string) version.string else null;
}

/// Whether `capabilities` holds the dotted path `capability`, such as `elicitation.form`.
fn hasCapability(capabilities: Value, capability: []const u8) bool {
    var at = capabilities;
    var parts = std.mem.splitScalar(u8, capability, '.');
    while (parts.next()) |part| {
        if (at != .object) return false;
        at = at.object.get(part) orelse return false;
    }
    return true;
}

/// `params` with the subscription `id` in its metadata.
fn subscribed(arena: Allocator, params: ?Value, id: jsonrpc.Id) Allocator.Error!?Value {
    var made: ObjectMap = if (params) |given| try given.object.clone(arena) else .empty;
    var meta: ObjectMap = .empty;
    try meta.put(arena, protocol.meta.subscription_id, switch (id) {
        .number => |number| .{ .integer = number },
        .string => |text| .{ .string = text },
    });
    try made.put(arena, "_meta", .{ .object = meta });
    return .{ .object = made };
}

fn send(arena: Allocator, sink: Channel, message: jsonrpc.Message) Allocator.Error!void {
    sink.send(try message.encode(arena));
}

fn notify(arena: Allocator, sink: Channel, method: []const u8, params: ?Value) Allocator.Error!void {
    try send(arena, sink, .{ .notification = .{ .method = method, .params = params } });
}
