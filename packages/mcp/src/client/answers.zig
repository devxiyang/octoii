//! What a client answers and keeps: the server's own requests — `ping`, `roots/list`, `elicitation/create` — answered
//! through the handler of the request they are for, else the client's, that request's time standing meanwhile; a
//! stateless server's questions gathered and their answers sent back; and the notifications the server sends apart,
//! kept for whoever reads the client's events.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const foundation = @import("foundation");
const typebox = @import("typebox");
const Client = @import("../Client.zig");
const jsonrpc = @import("foundation").jsonrpc;
const types = @import("../types.zig");
const results = @import("../results.zig");
const failure_ = @import("../failure.zig");
const Slot = failure_.Slot;
const Error = failure_.Error;
const Pending = @import("requests.zig").Pending;

/// What the server sends apart from any request.
pub const Event = union(enum) {
    tools_list_changed,
    prompts_list_changed,
    resources_list_changed,
    resource_updated: []const u8,
    log: types.LogMessage,
};

/// How many notifications are kept unread; the oldest goes past that.
const events_max = 1024;

/// Keeps a notification the client reads as an event; one it does not is passed over.
pub fn notified(client: *Client, arena: Allocator, notification: jsonrpc.Notification) Allocator.Error!void {
    _ = try eventOf(arena, notification) orelse return;
    const encoded = try (jsonrpc.Message{ .notification = notification }).encode(arena);
    client.lock.lockUncancelable(client.options.host.io);
    defer client.lock.unlock(client.options.host.io);
    if (client.events.items.len == events_max) client.gpa.free(client.events.orderedRemove(0));
    // An event there is no room for goes untold, as one past the oldest kept does.
    client.events.ensureUnusedCapacity(client.gpa, 1) catch return;
    client.events.appendAssumeCapacity(try client.gpa.dupe(u8, encoded));
}

/// The event a notification is; null for one that is none.
pub fn eventOf(arena: Allocator, notification: jsonrpc.Notification) Allocator.Error!?Event {
    const eql = std.mem.eql;
    const method = notification.method;
    const params: ObjectMap = if (notification.params) |given| (if (given == .object) given.object else .empty) else .empty;
    if (eql(u8, method, "notifications/tools/list_changed")) return .tools_list_changed;
    if (eql(u8, method, "notifications/prompts/list_changed")) return .prompts_list_changed;
    if (eql(u8, method, "notifications/resources/list_changed")) return .resources_list_changed;
    if (eql(u8, method, "notifications/resources/updated")) {
        const uri = params.get("uri") orelse return null;
        return if (uri == .string) .{ .resource_updated = uri.string } else null;
    }
    if (eql(u8, method, "notifications/message")) {
        const level = results.loggingLevel(params.get("level")) orelse return null;
        const logger = if (params.get("logger")) |given| (if (given == .string) given.string else null) else null;
        _ = arena;
        return .{ .log = .{ .level = level, .logger = logger, .data = params.get("data") orelse .null } };
    }
    return null;
}

/// The next event, in `arena`: one kept, else what the transport receives apart, waiting at most `wait_ms`; null where
/// none came, or the connection closed. A server's request received so is answered on the way.
pub fn nextEvent(client: *Client, arena: Allocator, wait_ms: ?u64) Allocator.Error!?Event {
    {
        client.lock.lockUncancelable(client.options.host.io);
        defer client.lock.unlock(client.options.host.io);
        if (client.events.items.len > 0) {
            const text = client.events.orderedRemove(0);
            defer client.gpa.free(text);
            const message = jsonrpc.parseOne(arena, text) catch unreachable;
            return eventOf(arena, message.notification);
        }
        if (client.state == .closed) return null;
    }
    var slot: Slot = .{ .arena = arena };
    while (true) {
        const incoming = client.transport.receive(&slot, wait_ms) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Failed => return null,
        };
        switch (incoming) {
            .message => |arrived| switch (arrived.message) {
                .notification => |notification| if (try eventOf(arena, notification)) |event| return event,
                .request => |asked| serve(client, &slot, asked, null) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Failed => return null,
                },
                else => {},
            },
            .quiet, .lost => return null,
            .closed => {
                @import("requests.zig").shut(client);
                return null;
            },
        }
    }
}

/// Answers a server's request, as a session-based server sends them: `ping`, `roots/list`, `elicitation/create`;
/// every other method, `sampling/createMessage` among them, is not found.
pub fn serve(client: *Client, slot: *Slot, request: jsonrpc.Request, related: ?*Pending) Error!void {
    var answering: Slot = .{ .arena = slot.arena };
    const reply: jsonrpc.Message = if (served(client, &answering, request, related)) |result|
        .{ .result = .{ .id = request.id, .result = result } }
    else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => .{ .failure = .{ .id = request.id, .@"error" = try errorOf(slot.arena, answering.failure.?) } },
    };
    if (client.currentState() == .closed) return;
    client.transport.send(slot, reply) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => client.report(try slot.failure.?.message(slot.arena)),
    };
}

/// The error a failed answer is sent as: the server's own code where it refused, invalid params for a request that
/// breaks the protocol, an internal error otherwise.
fn errorOf(arena: Allocator, failure: failure_.Failure) Allocator.Error!jsonrpc.ErrorObject {
    return switch (failure) {
        .refused => |refused| .{ .code = refused.code, .message = refused.message },
        .protocol => |text| .{ .code = jsonrpc.codes.invalid_params, .message = text },
        else => .{ .code = jsonrpc.codes.internal_error, .message = try failure.message(arena) },
    };
}

fn served(client: *Client, slot: *Slot, request: jsonrpc.Request, related: ?*Pending) Error!Value {
    const eql = std.mem.eql;
    if (eql(u8, request.method, "ping")) return .{ .object = .empty };
    if (eql(u8, request.method, "roots/list") and client.options.roots != null) return rootsResult(client, slot.arena);
    if (eql(u8, request.method, "elicitation/create") and client.options.elicitation != null) {
        const asked = try results.elicitRequest(slot, request.params);
        try offered(client, slot, asked);
        const target = elicitTarget(client, related);
        const handler = target.handler orelse return decline(slot.arena);
        const now = client.options.host.nowMs();
        if (target.pending) |pending| standing(client, pending, now, true);
        defer if (target.pending) |pending| standing(client, pending, client.options.host.nowMs(), false);
        return elicitResponse(slot, asked, try handler.answer(handler.context, slot.arena, asked));
    }
    return slot.fail(.{ .refused = .{ .code = jsonrpc.codes.method_not_found, .message = try slot.arena.print("Method not found: {s}", .{request.method}) } });
}

fn standing(client: *Client, pending: *Pending, now_ms: i64, stands: bool) void {
    client.lock.lockUncancelable(client.options.host.io);
    defer client.lock.unlock(client.options.host.io);
    if (stands) pending.pause(now_ms) else pending.unpause(now_ms);
}

/// Whose a session-based server's elicitation is: the request whose stream carried it, else the one request in flight
/// with a handler of its own; and its handler, that request's, else the client's.
fn elicitTarget(client: *Client, related: ?*Pending) struct { pending: ?*Pending, handler: ?Client.ElicitHandler } {
    const own = if (client.options.elicitation) |given| given.handler else null;
    if (related) |pending| return .{ .pending = pending, .handler = pending.elicit orelse own };
    client.lock.lockUncancelable(client.options.host.io);
    defer client.lock.unlock(client.options.host.io);
    var only: ?*Pending = null;
    for (client.pending.items) |pending| if (pending.elicit != null) {
        if (only != null) return .{ .pending = null, .handler = own };
        only = pending;
    };
    if (only) |pending| return .{ .pending = pending, .handler = pending.elicit };
    return .{ .pending = null, .handler = own };
}

/// Fails an elicitation in a mode the client does not offer, as invalid params.
fn offered(client: *Client, slot: *Slot, request: types.ElicitRequest) Error!void {
    const modes = client.options.elicitation orelse return refuseMode(slot, request);
    const takes = switch (request) {
        .form => modes.form,
        .url => modes.url,
    };
    if (!takes) return refuseMode(slot, request);
}

fn refuseMode(slot: *Slot, request: types.ElicitRequest) Error {
    return slot.fail(.{ .refused = .{ .code = jsonrpc.codes.invalid_params, .message = try slot.arena.print("This client does not offer {t} elicitation", .{std.meta.activeTag(request)}) } });
}

fn decline(arena: Allocator) Allocator.Error!Value {
    var made: ObjectMap = .empty;
    try made.put(arena, "action", .{ .string = "decline" });
    return .{ .object = made };
}

/// An answer to an elicitation as the server gets it: an accepted form's content, which must match the form; a
/// visited link's without.
fn elicitResponse(slot: *Slot, request: types.ElicitRequest, answer: types.ElicitResult) Error!Value {
    var made: ObjectMap = .empty;
    try made.put(slot.arena, "action", .{ .string = @tagName(answer) });
    const content = switch (answer) {
        .accept => |given| given,
        else => return .{ .object = made },
    };
    const form = switch (request) {
        .form => |form| form,
        .url => return .{ .object = made },
    };
    const given = content orelse Value{ .object = .empty };
    const problems = try typebox.problems(slot.arena, form.requestedSchema, given);
    if (problems.len > 0) return slot.fail(.{ .invalid_answer = try slot.arena.print("The answer to the elicitation does not match its form: {s}", .{try typebox.shown(slot.arena, problems)}) });
    try made.put(slot.arena, "content", given);
    return .{ .object = made };
}

fn rootsResult(client: *Client, arena: Allocator) Allocator.Error!Value {
    client.lock.lockUncancelable(client.options.host.io);
    defer client.lock.unlock(client.options.host.io);
    var made: ObjectMap = .empty;
    try made.put(arena, "roots", try foundation.json.toValue(arena, client.roots));
    return .{ .object = made };
}

/// A stateless server's questions, each one the client offers: an elicitation in a mode it offers, or its roots.
pub fn inputRequired(client: *Client, slot: *Slot, result: ObjectMap) Error!types.InputRequired {
    const given = result.get("inputRequests") orelse Value{ .object = .empty };
    if (given != .object) return slot.violated("The MCP server's input requests are not an object", .{});
    var requests: std.ArrayList(types.KeyedRequest) = .empty;
    var it = given.object.iterator();
    while (it.next()) |entry| try requests.append(slot.arena, .{ .key = entry.key_ptr.*, .request = try inputRequest(client, slot, entry.value_ptr.*) });
    const state = if (result.get("requestState")) |kept| (if (kept == .string) kept.string else null) else null;
    return .{ .requests = requests.items, .requestState = state };
}

fn inputRequest(client: *Client, slot: *Slot, given: Value) Error!types.InputRequest {
    const method = if (given == .object) (if (given.object.get("method")) |named| (if (named == .string) named.string else null) else null) else null;
    if (method) |named| {
        if (std.mem.eql(u8, named, "elicitation/create")) {
            const asked = try results.elicitRequest(slot, given.object.get("params"));
            try offered(client, slot, asked);
            return .{ .elicitation = asked };
        }
        if (std.mem.eql(u8, named, "roots/list") and client.options.roots != null) return .roots;
    }
    return slot.violated("The MCP server asked for {s}, which this client does not offer", .{method orelse "nothing it names"});
}

/// The person's answers to a stateless server's elicitations, one at a time, by the request's handler or the client's.
pub fn gathered(client: *Client, slot: *Slot, input: types.InputRequired, options: Client.RequestOptions) Error![]const types.KeyedAnswer {
    const handler = options.elicit orelse if (client.options.elicitation) |given| given.handler else null;
    var answered: std.ArrayList(types.KeyedAnswer) = .empty;
    for (input.requests) |each| switch (each.request) {
        .elicitation => |asked| try answered.append(slot.arena, .{ .key = each.key, .answer = if (handler) |given| try given.answer(given.context, slot.arena, asked) else .decline }),
        .roots => {},
    };
    return answered.items;
}

/// What a request is sent again with: each question's answer, checked against it, or the roots, and the server's
/// `requestState`.
pub fn inputParams(client: *Client, slot: *Slot, answered: types.InputAnswers) Error!ObjectMap {
    var responses: ObjectMap = .empty;
    for (answered.required.requests) |each| switch (each.request) {
        .roots => try responses.put(slot.arena, each.key, try rootsResult(client, slot.arena)),
        .elicitation => |asked| {
            const answer = for (answered.answers) |given| {
                if (std.mem.eql(u8, given.key, each.key)) break given.answer;
            } else return slot.fail(.{ .invalid_answer = try slot.arena.print("The MCP server's question {s} has no answer", .{each.key}) });
            try responses.put(slot.arena, each.key, try elicitResponse(slot, asked, answer));
        },
    };
    var params: ObjectMap = .empty;
    if (responses.count() > 0) try params.put(slot.arena, "inputResponses", .{ .object = responses });
    if (answered.required.requestState) |state| try params.put(slot.arena, "requestState", .{ .string = state });
    return params;
}
