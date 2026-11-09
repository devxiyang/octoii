//! An MCP server of one client: what a host offers of its tools, resources and prompts, spoken in either era — a
//! stateless request read by the version its metadata names, a session opened by `initialize` — over whatever carries
//! its messages; stdio's runner is beside it. A message is handed to it as it comes. What a provider answers runs as
//! a task of its own on the io, so that a long call blocks no other, and a request the client cancels has its task
//! cancelled. Everything of a request lives in an arena of its own until it is answered.
const Server = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const foundation = @import("foundation");
const jsonrpc = @import("jsonrpc.zig");
const protocol = @import("protocol.zig");
const types = @import("types.zig");
const results = @import("results.zig");
const memory = @import("memory.zig");
const call_ = @import("server/call.zig");
const wire = @import("server/wire.zig");

pub const Call = call_.Call;
pub const Error = call_.Error;
pub const Peer = call_.Peer;

/// The tools a server offers, which may change: `toolsChanged` tells the clients that listen.
pub const Tools = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The tools offered now, in `arena`.
        list: *const fn (context: *anyopaque, arena: Allocator) Allocator.Error![]const types.Tool,
        /// Calls the tool `name` with `arguments`, an object; a tool it does not have it refuses with invalid params.
        call: *const fn (context: *anyopaque, call: *Call, name: []const u8, arguments: Value) Error!types.CallToolResult,
    };
};

pub const Resources = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        list: *const fn (context: *anyopaque, arena: Allocator) Allocator.Error![]const types.Resource,
        templates: *const fn (context: *anyopaque, arena: Allocator) Allocator.Error![]const types.ResourceTemplate,
        /// The contents at `uri`; one it does not have it refuses with `resource_not_found`.
        read: *const fn (context: *anyopaque, call: *Call, uri: []const u8) Error![]const types.ResourceContents,
    };
};

pub const Prompts = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        list: *const fn (context: *anyopaque, arena: Allocator) Allocator.Error![]const types.Prompt,
        /// The prompt `name` with `arguments`, an object of strings; one it does not have it refuses with invalid
        /// params.
        get: *const fn (context: *anyopaque, call: *Call, name: []const u8, arguments: ObjectMap) Error!types.GetPromptResult,
    };
};

/// The error code of a resource the server does not have.
pub const resource_not_found = -32002;

pub const Options = struct {
    info: types.Implementation,
    instructions: ?[]const u8 = null,
    tools: ?Tools = null,
    resources: ?Resources = null,
    prompts: ?Prompts = null,
    /// The eras it speaks.
    eras: []const protocol.Era = &.{ .modern, .legacy },
    /// How many items a page of a list holds; none, all.
    page_size: ?usize = null,
};

/// A request a provider answers, as a task: its arena, the request and the answers to its questions so far.
const Running = struct {
    arena: std.heap.ArenaAllocator,
    era: protocol.Era,
    request: jsonrpc.Request,
    answers: ObjectMap,
    future: ?Io.Future(void) = null,
    done: bool = false,
    /// The client cancelled it before its task was kept.
    cancelled: bool = false,
};

/// A session's question to the client for a request, waiting for the answer to run the request again with.
const Ask = struct {
    arena: std.heap.ArenaAllocator,
    id: i64,
    request: jsonrpc.Request,
    answers: ObjectMap,
    key: []const u8,
};

/// A stateless client's subscription, kept open: its request's id and what it acknowledged.
const Listener = struct { id: jsonrpc.Id, tools: bool, prompts: bool, resources: bool };

/// What a session keeps of its client, from `initialize`.
const Session = struct {
    open: bool = false,
    initialized: bool = false,
    version: []const u8 = "",
    capabilities: Value = .{ .object = .empty },
    log_level: ?types.LoggingLevel = null,
};

gpa: Allocator,
io: Io,
options: Options,
/// Guards everything below.
lock: Io.Mutex = .init,
peer: ?Peer = null,
session: Session = .{},
session_arena: std.heap.ArenaAllocator,
running: std.ArrayList(*Running) = .empty,
asks: std.ArrayList(*Ask) = .empty,
listeners: std.ArrayList(Listener) = .empty,
next_ask: i64 = 1,

pub fn init(gpa: Allocator, io: Io, options: Options) Allocator.Error!*Server {
    const server = try gpa.create(Server);
    errdefer gpa.destroy(server);
    server.* = .{ .gpa = gpa, .io = io, .options = options, .session_arena = .init(gpa) };
    return server;
}

/// Stops what runs and lets the server go, once no message is being handed to it.
pub fn deinit(server: *Server) void {
    server.stop();
    server.running.deinit(server.gpa);
    server.asks.deinit(server.gpa);
    server.listeners.deinit(server.gpa);
    server.session_arena.deinit();
    server.gpa.destroy(server);
}

/// The client went away: every request's task cancelled, its questions and subscriptions dropped. Not while a
/// message is being handed to the server.
pub fn stop(server: *Server) void {
    while (server.takeAny()) |running| server.release(running, true);
    server.lock.lockUncancelable(server.io);
    defer server.lock.unlock(server.io);
    for (server.asks.items) |ask| destroyAsk(server.gpa, ask);
    server.asks.clearRetainingCapacity();
    for (server.listeners.items) |listener| freeId(server.gpa, listener.id);
    server.listeners.clearRetainingCapacity();
}

/// Takes `text`, a message from the client, its answers sent to `peer`, which the server keeps for what it sends
/// later.
pub fn handle(server: *Server, peer: Peer, text: []const u8) void {
    server.reap();
    {
        server.lock.lockUncancelable(server.io);
        defer server.lock.unlock(server.io);
        server.peer = peer;
    }
    var scratch_arena: std.heap.ArenaAllocator = .init(server.gpa);
    defer scratch_arena.deinit();
    server.handled(scratch_arena.allocator(), text) catch {};
}

/// The server as the in-process transport takes one.
pub fn memoryServer(server: *Server) memory.Server {
    return .{ .context = server, .vtable = &.{ .handle = memoryHandle, .closed = memoryClosed } };
}

fn memoryHandle(context: *anyopaque, sink: memory.Sink, text: []const u8) void {
    const server: *Server = @ptrCast(@alignCast(context));
    server.handle(.{ .context = sink.pair, .send = struct {
        fn send(pair: *anyopaque, message: []const u8) void {
            (memory.Sink{ .pair = @ptrCast(@alignCast(pair)) }).send(message);
        }
    }.send }, text);
}

fn memoryClosed(context: *anyopaque) void {
    const server: *Server = @ptrCast(@alignCast(context));
    server.stop();
}

/// Tells the clients that listen that the tools changed.
pub fn toolsChanged(server: *Server) void {
    server.changed(.tools);
}

pub fn resourcesChanged(server: *Server) void {
    server.changed(.resources);
}

pub fn promptsChanged(server: *Server) void {
    server.changed(.prompts);
}

const Kind = enum { tools, resources, prompts };

/// A list's change, told to a session where it opened, and to each stateless subscription that asked for it.
fn changed(server: *Server, kind: Kind) void {
    var scratch_arena: std.heap.ArenaAllocator = .init(server.gpa);
    defer scratch_arena.deinit();
    const arena = scratch_arena.allocator();
    const method = switch (kind) {
        inline else => |named| "notifications/" ++ @tagName(named) ++ "/list_changed",
    };
    var ids: std.ArrayList(jsonrpc.Id) = .empty;
    const session_listens = blk: {
        server.lock.lockUncancelable(server.io);
        defer server.lock.unlock(server.io);
        for (server.listeners.items) |listener| {
            const wants = switch (kind) {
                .tools => listener.tools,
                .resources => listener.resources,
                .prompts => listener.prompts,
            };
            if (wants) ids.append(arena, copiedId(arena, listener.id) catch return) catch return;
        }
        break :blk server.session.initialized;
    };
    if (session_listens) server.notify(arena, method, null) catch return;
    for (ids.items) |id| server.notify(arena, method, wire.subscribed(arena, null, id) catch return) catch return;
}

fn handled(server: *Server, arena: Allocator, text: []const u8) Allocator.Error!void {
    const message = jsonrpc.parseOne(arena, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotJsonRpc => {
            const json = std.json.validate(arena, text) catch false;
            const refusal: jsonrpc.ErrorObject = if (json) .{ .code = jsonrpc.codes.invalid_request, .message = "Not a JSON-RPC message" } else .{ .code = jsonrpc.codes.parse_error, .message = "Not JSON" };
            return server.send(arena, .{ .failure = .{ .id = null, .@"error" = refusal } });
        },
    };
    switch (message) {
        .request => |request| try server.requested(arena, request),
        .notification => |notification| try server.notified(arena, notification),
        .result => |result| try server.answered(result.id, result.result),
        .failure => |failed| try server.refusedAnswer(arena, failed),
    }
}

fn speaks(server: *const Server, era: protocol.Era) bool {
    return std.mem.indexOfScalar(protocol.Era, server.options.eras, era) != null;
}

fn requested(server: *Server, arena: Allocator, request: jsonrpc.Request) Allocator.Error!void {
    const params = wire.paramsOf(request);
    if (wire.modernVersion(params)) |version| if (server.speaks(.modern)) return server.modernRequest(arena, request, version);
    if (std.mem.eql(u8, request.method, "initialize") and server.speaks(.legacy)) return server.reply(arena, request.id, .legacy, try server.initialize(arena, params));
    if (!server.sessionOpen()) return server.refuse(arena, request.id, jsonrpc.codes.method_not_found, "Method not found: {s}", .{request.method});
    const eql = std.mem.eql;
    if (eql(u8, request.method, "ping")) return server.reply(arena, request.id, .legacy, .{ .object = .empty });
    if (eql(u8, request.method, "logging/setLevel")) {
        const level = wire.loggingLevel(params.get("level")) orelse return server.refuse(arena, request.id, jsonrpc.codes.invalid_params, "Unknown log level", .{});
        server.lock.lockUncancelable(server.io);
        server.session.log_level = level;
        server.lock.unlock(server.io);
        return server.reply(arena, request.id, .legacy, .{ .object = .empty });
    }
    return server.common(arena, request, .legacy, .empty);
}

/// A request of the current protocol: its version checked, then answered as its method says.
fn modernRequest(server: *Server, arena: Allocator, request: jsonrpc.Request, version: []const u8) Allocator.Error!void {
    if (!wire.isModernVersion(version)) return server.send(arena, .{ .failure = .{ .id = request.id, .@"error" = try wire.unsupportedVersion(arena, version, server.speaks(.legacy)) } });
    const eql = std.mem.eql;
    if (eql(u8, request.method, "server/discover")) return server.reply(arena, request.id, .modern, try server.discover(arena));
    if (eql(u8, request.method, "subscriptions/listen")) return server.listen(arena, request);
    return server.common(arena, request, .modern, try wire.givenAnswers(arena, wire.paramsOf(request)));
}

/// The methods both eras have: lists answered at once, and what a provider answers started as a task.
fn common(server: *Server, arena: Allocator, request: jsonrpc.Request, era: protocol.Era, answers: ObjectMap) Allocator.Error!void {
    const eql = std.mem.eql;
    const method = request.method;
    const offered = for ([_]struct { []const u8, bool }{
        .{ "tools/", server.options.tools != null },
        .{ "resources/", server.options.resources != null },
        .{ "prompts/", server.options.prompts != null },
    }) |each| {
        if (std.mem.startsWith(u8, method, each[0])) break each[1];
    } else false;
    if (!offered) return server.refuse(arena, request.id, jsonrpc.codes.method_not_found, "Method not found: {s}", .{method});
    if (eql(u8, method, "tools/call") or eql(u8, method, "resources/read") or eql(u8, method, "prompts/get")) return server.startTask(request, era, answers);
    const start = wire.cursorOf(wire.paramsOf(request)) orelse return server.refuse(arena, request.id, jsonrpc.codes.invalid_params, "Invalid cursor", .{});
    const size = server.options.page_size;
    const listed = if (eql(u8, method, "tools/list"))
        try wire.page(arena, try server.options.tools.?.vtable.list(server.options.tools.?.context, arena), start, size, "tools")
    else if (eql(u8, method, "resources/list"))
        try wire.page(arena, try server.options.resources.?.vtable.list(server.options.resources.?.context, arena), start, size, "resources")
    else if (eql(u8, method, "resources/templates/list"))
        try wire.page(arena, try server.options.resources.?.vtable.templates(server.options.resources.?.context, arena), start, size, "resourceTemplates")
    else if (eql(u8, method, "prompts/list"))
        try wire.page(arena, try server.options.prompts.?.vtable.list(server.options.prompts.?.context, arena), start, size, "prompts")
    else
        return server.refuse(arena, request.id, jsonrpc.codes.method_not_found, "Method not found: {s}", .{method});
    return server.reply(arena, request.id, era, listed);
}

fn discover(server: *Server, arena: Allocator) Allocator.Error!Value {
    var result: ObjectMap = .empty;
    try result.put(arena, "supportedVersions", try foundation.json.toValue(arena, protocol.modern_versions));
    try result.put(arena, "capabilities", try server.capabilities(arena));
    var meta: ObjectMap = .empty;
    try meta.put(arena, protocol.meta.server_info, try foundation.json.toValue(arena, server.options.info));
    try result.put(arena, "_meta", .{ .object = meta });
    if (server.options.instructions) |text| try result.put(arena, "instructions", .{ .string = text });
    return .{ .object = result };
}

/// Opens a session: the client's version where the server speaks it, else its newest, and the client's
/// capabilities kept.
fn initialize(server: *Server, arena: Allocator, params: ObjectMap) Allocator.Error!Value {
    const offered = wire.stringOf(params.get("protocolVersion")) orelse "";
    const version = for (protocol.legacy_versions) |each| {
        if (std.mem.eql(u8, each, offered)) break each;
    } else protocol.legacy_versions[0];
    {
        server.lock.lockUncancelable(server.io);
        defer server.lock.unlock(server.io);
        _ = server.session_arena.reset(.retain_capacity);
        server.session = .{ .open = true, .version = version, .capabilities = try foundation.json.toValue(server.session_arena.allocator(), params.get("capabilities") orelse Value{ .object = .empty }) };
    }
    var result: ObjectMap = .empty;
    try result.put(arena, "protocolVersion", .{ .string = version });
    try result.put(arena, "capabilities", try server.capabilities(arena));
    try result.put(arena, "serverInfo", try foundation.json.toValue(arena, server.options.info));
    if (server.options.instructions) |text| try result.put(arena, "instructions", .{ .string = text });
    return .{ .object = result };
}

/// What the server offers: its lists, which change, and logging.
fn capabilities(server: *const Server, arena: Allocator) Allocator.Error!Value {
    var made: ObjectMap = .empty;
    const changing = [_]struct { []const u8, bool }{
        .{ "tools", server.options.tools != null },
        .{ "resources", server.options.resources != null },
        .{ "prompts", server.options.prompts != null },
    };
    for (changing) |each| if (each[1]) {
        var group: ObjectMap = .empty;
        try group.put(arena, "listChanged", .{ .bool = true });
        try made.put(arena, each[0], .{ .object = group });
    };
    try made.put(arena, "logging", .{ .object = .empty });
    return .{ .object = made };
}

/// A stateless subscription: kept open, and acknowledged with the list changes the server will send; it subscribes
/// to no resource's contents.
fn listen(server: *Server, arena: Allocator, request: jsonrpc.Request) Allocator.Error!void {
    const wanted = try results.subscriptionFilter(arena, wire.paramsOf(request).get("notifications"));
    const listener: Listener = .{
        .id = try copiedId(server.gpa, request.id),
        .tools = wanted.toolsListChanged and server.options.tools != null,
        .prompts = wanted.promptsListChanged and server.options.prompts != null,
        .resources = wanted.resourcesListChanged and server.options.resources != null,
    };
    {
        server.lock.lockUncancelable(server.io);
        defer server.lock.unlock(server.io);
        server.listeners.append(server.gpa, listener) catch |err| {
            freeId(server.gpa, listener.id);
            return err;
        };
    }
    const acknowledged: types.SubscriptionFilter = .{ .toolsListChanged = listener.tools, .promptsListChanged = listener.prompts, .resourcesListChanged = listener.resources };
    var params: ObjectMap = .empty;
    try params.put(arena, "notifications", try foundation.json.toValue(arena, acknowledged));
    try server.notify(arena, "notifications/subscriptions/acknowledged", try wire.subscribed(arena, params, request.id));
}

fn notified(server: *Server, arena: Allocator, notification: jsonrpc.Notification) Allocator.Error!void {
    const eql = std.mem.eql;
    if (eql(u8, notification.method, "notifications/initialized")) {
        server.lock.lockUncancelable(server.io);
        defer server.lock.unlock(server.io);
        if (server.session.open) server.session.initialized = true;
        return;
    }
    if (!eql(u8, notification.method, "notifications/cancelled")) return;
    const params: ObjectMap = if (notification.params) |given| (if (given == .object) given.object else .empty) else .empty;
    const id = jsonrpc.Id.of(params.get("requestId") orelse return) orelse return;
    try server.cancel(arena, id);
}

/// The client cancelled the request `id`: a subscription closed, a question waiting withdrawn, a task cancelled. A
/// cancelled request is not answered.
fn cancel(server: *Server, arena: Allocator, id: jsonrpc.Id) Allocator.Error!void {
    server.lock.lockUncancelable(server.io);
    for (server.listeners.items, 0..) |listener, index| if (listener.id.eql(id)) {
        freeId(server.gpa, server.listeners.orderedRemove(index).id);
        server.lock.unlock(server.io);
        return;
    };
    for (server.asks.items, 0..) |ask, index| if (ask.request.id.eql(id)) {
        _ = server.asks.orderedRemove(index);
        server.lock.unlock(server.io);
        defer destroyAsk(server.gpa, ask);
        var params: ObjectMap = .empty;
        try params.put(arena, "requestId", .{ .integer = ask.id });
        return server.notify(arena, "notifications/cancelled", .{ .object = params });
    };
    for (server.running.items, 0..) |running, index| if (!running.done and running.request.id.eql(id)) {
        if (running.future == null) {
            running.cancelled = true;
            server.lock.unlock(server.io);
            return;
        }
        _ = server.running.orderedRemove(index);
        server.lock.unlock(server.io);
        return server.release(running, true);
    };
    server.lock.unlock(server.io);
}

/// A session's answer to the server's question: the request that asked it runs again with it.
fn answered(server: *Server, id: jsonrpc.Id, result: Value) Allocator.Error!void {
    const ask = server.takeAsk(id) orelse return;
    defer destroyAsk(server.gpa, ask);
    try ask.answers.put(ask.arena.allocator(), ask.key, result);
    try server.startTask(ask.request, .legacy, ask.answers);
}

/// A session's refusal of the server's question: the request that asked it fails with it.
fn refusedAnswer(server: *Server, arena: Allocator, failed: jsonrpc.Failure) Allocator.Error!void {
    const ask = server.takeAsk(failed.id orelse return) orelse return;
    defer destroyAsk(server.gpa, ask);
    try server.send(arena, .{ .failure = .{ .id = ask.request.id, .@"error" = failed.@"error" } });
}

fn takeAsk(server: *Server, id: jsonrpc.Id) ?*Ask {
    if (id != .number) return null;
    server.lock.lockUncancelable(server.io);
    defer server.lock.unlock(server.io);
    for (server.asks.items, 0..) |ask, index| if (ask.id == id.number) return server.asks.orderedRemove(index);
    return null;
}

fn destroyAsk(gpa: Allocator, ask: *Ask) void {
    ask.arena.deinit();
    gpa.destroy(ask);
}

/// Starts `request` as a task with `answers`, both copied into its own arena; on an io that runs nothing
/// concurrently, it runs now, and nothing cancels it.
fn startTask(server: *Server, request: jsonrpc.Request, era: protocol.Era, answers: ObjectMap) Allocator.Error!void {
    const running = try server.gpa.create(Running);
    errdefer server.gpa.destroy(running);
    running.* = .{ .arena = .init(server.gpa), .era = era, .request = undefined, .answers = undefined };
    errdefer running.arena.deinit();
    const arena = running.arena.allocator();
    running.request = (try wire.copied(arena, .{ .request = request })).request;
    running.answers = (try foundation.json.toValue(arena, Value{ .object = answers })).object;
    {
        server.lock.lockUncancelable(server.io);
        defer server.lock.unlock(server.io);
        try server.running.append(server.gpa, running);
    }
    const future = server.io.concurrent(run, .{ server, running }) catch {
        run(server, running);
        server.lock.lockUncancelable(server.io);
        _ = server.running.orderedRemove(std.mem.indexOfScalar(*Running, server.running.items, running).?);
        server.lock.unlock(server.io);
        return server.release(running, false);
    };
    server.lock.lockUncancelable(server.io);
    running.future = future;
    const cancelled = running.cancelled and !running.done;
    if (cancelled) _ = server.running.orderedRemove(std.mem.indexOfScalar(*Running, server.running.items, running).?);
    server.lock.unlock(server.io);
    if (cancelled) server.release(running, true);
}

fn run(server: *Server, running: *Running) void {
    defer {
        server.lock.lockUncancelable(server.io);
        running.done = true;
        server.lock.unlock(server.io);
    }
    server.answer(running) catch {};
}

/// Answers a running request with what its provider gives: its result, its refusal, its question; nothing where
/// it was cancelled.
fn answer(server: *Server, running: *Running) Allocator.Error!void {
    const arena = running.arena.allocator();
    var call = try server.callOf(running);
    const id = running.request.id;
    const result = server.provided(&call, running.request) catch |err| switch (err) {
        error.Canceled => return,
        error.OutOfMemory => return server.send(arena, .{ .failure = .{ .id = id, .@"error" = .{ .code = jsonrpc.codes.internal_error, .message = "The MCP server ran out of memory" } } }),
        error.Refused => return server.send(arena, .{ .failure = .{ .id = id, .@"error" = call.refusal.? } }),
        error.Asked => return server.askClient(running, call.asked.?),
    };
    try server.send(arena, .{ .result = .{ .id = id, .result = try wire.complete(arena, running.era, result) } });
}

/// What a request's handler reaches: a stateless request's metadata, a session's capabilities and log level.
fn callOf(server: *Server, running: *Running) Allocator.Error!Call {
    const arena = running.arena.allocator();
    const meta = wire.metaOf(wire.paramsOf(running.request));
    server.lock.lockUncancelable(server.io);
    defer server.lock.unlock(server.io);
    const modern = running.era == .modern;
    return .{
        .arena = arena,
        .era = running.era,
        .peer = server.peer.?,
        .progress_token = meta.get("progressToken"),
        .log_level = if (modern) wire.loggingLevel(meta.get(protocol.meta.log_level)) else server.session.log_level,
        .capabilities = if (modern) meta.get(protocol.meta.client_capabilities) orelse .{ .object = .empty } else try foundation.json.toValue(arena, server.session.capabilities),
        .answers = running.answers,
    };
}

/// The result a provider gives a request, as JSON.
fn provided(server: *Server, call: *Call, request: jsonrpc.Request) Error!Value {
    const params = wire.paramsOf(request);
    const eql = std.mem.eql;
    if (eql(u8, request.method, "tools/call")) {
        const name = wire.stringOf(params.get("name")) orelse return call.refuse(jsonrpc.codes.invalid_params, "The tool call names no tool", .{});
        const arguments = params.get("arguments") orelse Value{ .object = .empty };
        if (arguments != .object) return call.refuse(jsonrpc.codes.invalid_params, "The arguments of {s} are not an object", .{name});
        const tools = server.options.tools.?;
        return foundation.json.toValue(call.arena, try tools.vtable.call(tools.context, call, name, arguments));
    }
    if (eql(u8, request.method, "resources/read")) {
        const uri = wire.stringOf(params.get("uri")) orelse return call.refuse(jsonrpc.codes.invalid_params, "The read names no resource", .{});
        const resources = server.options.resources.?;
        return foundation.json.toValue(call.arena, types.ReadResourceResult{ .contents = try resources.vtable.read(resources.context, call, uri) });
    }
    const name = wire.stringOf(params.get("name")) orelse return call.refuse(jsonrpc.codes.invalid_params, "The request names no prompt", .{});
    const arguments = params.get("arguments") orelse Value{ .object = .empty };
    if (arguments != .object) return call.refuse(jsonrpc.codes.invalid_params, "The arguments of {s} are not an object", .{name});
    for (arguments.object.values()) |value| if (value != .string) return call.refuse(jsonrpc.codes.invalid_params, "The arguments of {s} are not all strings", .{name});
    const prompts = server.options.prompts.?;
    return foundation.json.toValue(call.arena, try prompts.vtable.get(prompts.context, call, name, arguments.object));
}

/// Asks the client a request's question: a stateless request answered `input_required`, its answers so far in its
/// `requestState`; a session sent the server's own request, the request kept until the answer comes.
fn askClient(server: *Server, running: *Running, asked: Call.Asked) Allocator.Error!void {
    const arena = running.arena.allocator();
    if (running.era == .modern) {
        const result = try wire.inputRequired(arena, asked.key, asked.method, asked.params, running.answers);
        return server.send(arena, .{ .result = .{ .id = running.request.id, .result = result } });
    }
    const kept = try server.gpa.create(Ask);
    errdefer server.gpa.destroy(kept);
    kept.* = .{ .arena = .init(server.gpa), .id = 0, .request = undefined, .answers = undefined, .key = undefined };
    errdefer kept.arena.deinit();
    const kept_arena = kept.arena.allocator();
    kept.request = (try wire.copied(kept_arena, .{ .request = running.request })).request;
    kept.answers = (try foundation.json.toValue(kept_arena, Value{ .object = running.answers })).object;
    kept.key = try kept_arena.dupe(u8, asked.key);
    {
        server.lock.lockUncancelable(server.io);
        defer server.lock.unlock(server.io);
        kept.id = server.next_ask;
        server.next_ask += 1;
        try server.asks.append(server.gpa, kept);
    }
    try server.send(arena, .{ .request = .{ .id = .{ .number = kept.id }, .method = asked.method, .params = asked.params } });
}

/// Awaits the tasks that are done, letting them go.
fn reap(server: *Server) void {
    while (true) {
        const running = blk: {
            server.lock.lockUncancelable(server.io);
            defer server.lock.unlock(server.io);
            for (server.running.items, 0..) |each, index| if (each.done and each.future != null) break :blk server.running.orderedRemove(index);
            return;
        };
        server.release(running, false);
    }
}

/// Any task, taken from those kept.
fn takeAny(server: *Server) ?*Running {
    server.lock.lockUncancelable(server.io);
    defer server.lock.unlock(server.io);
    return server.running.pop();
}

/// Lets a task go, cancelled first where `cancelling`, else awaited.
fn release(server: *Server, running: *Running, cancelling: bool) void {
    if (running.future) |*future| {
        if (cancelling) future.cancel(server.io) else future.await(server.io);
    }
    running.arena.deinit();
    server.gpa.destroy(running);
}

fn send(server: *Server, arena: Allocator, message: jsonrpc.Message) Allocator.Error!void {
    const peer = blk: {
        server.lock.lockUncancelable(server.io);
        defer server.lock.unlock(server.io);
        break :blk server.peer orelse return;
    };
    peer.send(peer.context, try message.encode(arena));
}

fn notify(server: *Server, arena: Allocator, method: []const u8, params: ?Value) Allocator.Error!void {
    try server.send(arena, .{ .notification = .{ .method = method, .params = params } });
}

fn reply(server: *Server, arena: Allocator, id: jsonrpc.Id, era: protocol.Era, result: Value) Allocator.Error!void {
    try server.send(arena, .{ .result = .{ .id = id, .result = try wire.complete(arena, era, result) } });
}

fn refuse(server: *Server, arena: Allocator, id: jsonrpc.Id, code: i64, comptime text: []const u8, arguments: anytype) Allocator.Error!void {
    try server.send(arena, .{ .failure = .{ .id = id, .@"error" = .{ .code = code, .message = try arena.print(text, arguments) } } });
}

fn sessionOpen(server: *Server) bool {
    server.lock.lockUncancelable(server.io);
    defer server.lock.unlock(server.io);
    return server.session.open;
}

fn copiedId(allocator: Allocator, id: jsonrpc.Id) Allocator.Error!jsonrpc.Id {
    return switch (id) {
        .number => id,
        .string => |text| .{ .string = try allocator.dupe(u8, text) },
    };
}

fn freeId(gpa: Allocator, id: jsonrpc.Id) void {
    if (id == .string) gpa.free(id.string);
}
