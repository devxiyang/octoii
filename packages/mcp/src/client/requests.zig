//! A client's requests: the protocol settled on as it connects, each request sent and waited for on its caller's task
//! — its time, which stops while its question waits, its progress, the server's questions answered on the way — a
//! stateless request whose stream broke sent again, and one a stateless server answers `input_required` gathered and
//! sent again with its answers.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const foundation = @import("foundation");
const typebox = @import("typebox");
const Header = foundation.http.Header;
const Client = @import("../Client.zig");
const RequestOptions = Client.RequestOptions;
const jsonrpc = @import("foundation").jsonrpc;
const protocol = @import("../protocol.zig");
const types = @import("../types.zig");
const results = @import("../results.zig");
const headers_ = @import("../headers.zig");
const failure_ = @import("../failure.zig");
const Failure = failure_.Failure;
const Slot = failure_.Slot;
const Error = failure_.Error;
const answers = @import("answers.zig");
const object = @import("object.zig");

/// A request in flight: whose question stops its time, and whose handler answers it.
pub const Pending = struct {
    id: i64,
    elicit: ?Client.ElicitHandler,
    /// How many of its questions wait, since when its time stands, and how long it stood before.
    pauses: u32 = 0,
    paused_at_ms: i64 = 0,
    paused_ms: i64 = 0,

    /// Its time stands while a question waits for its answer; the client's lock is held.
    pub fn pause(pending: *Pending, now_ms: i64) void {
        pending.pauses += 1;
        if (pending.pauses == 1) pending.paused_at_ms = now_ms;
    }

    pub fn unpause(pending: *Pending, now_ms: i64) void {
        if (pending.pauses == 0) return;
        pending.pauses -= 1;
        if (pending.pauses == 0) pending.paused_ms += now_ms - pending.paused_at_ms;
    }

    /// How long its time has stood, so far.
    fn stood(pending: *const Pending, now_ms: i64) i64 {
        return pending.paused_ms + if (pending.pauses > 0) now_ms - pending.paused_at_ms else 0;
    }
};

/// A request as it is sent: its options, and before the client settled, its era, version, headers and id.
pub const Attempt = struct {
    options: RequestOptions = .{},
    era: ?protocol.Era = null,
    version: ?[]const u8 = null,
    headers: []const Header = &.{},
    /// How long it waits; none, the options' or the client's. `forever` waits without end.
    timeout_ms: ?u64 = null,
};

/// A wait without end, as a subscription's.
pub const forever = std.math.maxInt(u64);

/// A failure of an attempt, or its stream lost before its answer.
const AttemptError = Error || error{Lost};

/// Settles on a protocol with the server, `server/discover` first.
pub fn settle(client: *Client, slot: *Slot) Error!void {
    if (try discover(client, slot, protocol.version) == .legacy) try initialize(client, slot);
}

/// `server/discover` in `version`: which era the server is of, and for a stateless one, what it offers.
fn discover(client: *Client, slot: *Slot, version: []const u8) Error!protocol.Era {
    const result = attempt(client, slot, "server/discover", .empty, .{ .era = .modern, .version = version, .timeout_ms = client.options.probe_timeout_ms }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Lost => return .legacy,
        error.Failed => return eraAfterRefusal(client, slot, version),
    };
    // What is no discovery result comes from a server that does not know the method.
    const supported = result.get("supportedVersions") orelse return .legacy;
    const capabilities = result.get("capabilities") orelse return .legacy;
    if (supported != .array or capabilities != .object) return .legacy;
    const meta = result.get("_meta");
    const server_info = if (meta) |given| (if (given == .object) given.object.get(protocol.meta.server_info) else null) else null;
    try settleWith(client, .modern, version, capabilities, results.implementation(server_info), result.get("instructions"));
    return .modern;
}

/// What a refused `server/discover` says: an unsupported version names those the server speaks; another error only a
/// stateless server gives is a real failure; anything else, a session-based server.
fn eraAfterRefusal(client: *Client, slot: *Slot, version: []const u8) Error!protocol.Era {
    const failure = slot.failure.?;
    switch (failure) {
        .refused => |refused| {
            if (refused.code == protocol.codes.unsupported_protocol_version) return unsupportedVersion(client, slot, version, refused.data);
            if (protocol.isModernCode(refused.code)) return error.Failed;
        },
        .http, .timeout => {},
        else => return error.Failed,
    }
    slot.failure = null;
    return .legacy;
}

fn unsupportedVersion(client: *Client, slot: *Slot, version: []const u8, data: ?Value) Error!protocol.Era {
    var supported: std.ArrayList([]const u8) = .empty;
    if (data) |given| if (given == .object) if (given.object.get("supported")) |named| if (named == .array) {
        for (named.array.items) |each| if (each == .string) try supported.append(slot.arena, each.string);
    };
    for (protocol.modern_versions) |modern| {
        if (std.mem.eql(u8, modern, version)) continue;
        for (supported.items) |each| if (std.mem.eql(u8, each, modern)) {
            slot.failure = null;
            return discover(client, slot, modern);
        };
    }
    for (supported.items) |each| if (protocol.isLegacyVersion(each)) {
        slot.failure = null;
        return .legacy;
    };
    const named = if (supported.items.len == 0) "no version it names" else try std.mem.join(slot.arena, ", ", supported.items);
    return slot.violated("The MCP server speaks {s}, none of which this client speaks", .{named});
}

/// The session-based handshake: `initialize` with the newest such version, then `notifications/initialized`.
fn initialize(client: *Client, slot: *Slot) Error!void {
    var params: ObjectMap = .empty;
    try params.put(slot.arena, "protocolVersion", .{ .string = protocol.legacy_versions[0] });
    try params.put(slot.arena, "capabilities", try capabilitiesOf(client, slot.arena, .legacy));
    try params.put(slot.arena, "clientInfo", try foundation.json.toValue(slot.arena, client.options.client));
    const result = attempt(client, slot, "initialize", params, .{ .era = .legacy }) catch |err| return lostAs(slot, err, "initialize");
    const version = result.get("protocolVersion") orelse Value{ .null = {} };
    if (version != .string or !protocol.isLegacyVersion(version.string)) {
        return slot.violated("The MCP server answered initialize with the protocol version {s}, which this client does not speak", .{try foundation.json.encode(slot.arena, version)});
    }
    try settleWith(client, .legacy, version.string, result.get("capabilities") orelse .{ .object = .empty }, results.implementation(result.get("serverInfo")), result.get("instructions"));
    try client.transport.send(slot, .{ .notification = .{ .method = "notifications/initialized" } });
}

/// Keeps what the client settled on, as long as the client, and tells the transport.
fn settleWith(client: *Client, era: protocol.Era, version: []const u8, capabilities: Value, server_info: ?types.Implementation, instructions: ?Value) Error!void {
    const arena = client.lasting_arena.allocator();
    const kept: Client.Settled = .{
        .era = era,
        .version = try arena.dupe(u8, version),
        .capabilities = try object.copied(arena, capabilities),
        .server = if (server_info) |given| .{ .name = try arena.dupe(u8, given.name), .version = try arena.dupe(u8, given.version) } else null,
        .instructions = if (instructions) |given| (if (given == .string) try arena.dupe(u8, given.string) else null) else null,
    };
    {
        client.lock.lockUncancelable(client.options.host.io);
        defer client.lock.unlock(client.options.host.io);
        client.settled = kept;
    }
    client.transport.negotiated(kept.version, era);
}

/// The client features this client offers: elicitation in the modes it offers, and roots; never sampling. A
/// session-based server is told the roots may change.
pub fn capabilitiesOf(client: *const Client, arena: Allocator, era: protocol.Era) Allocator.Error!Value {
    var capabilities: ObjectMap = .empty;
    if (client.options.elicitation) |offered| {
        var modes: ObjectMap = .empty;
        if (offered.form) try modes.put(arena, "form", .{ .object = .empty });
        if (offered.url) try modes.put(arena, "url", .{ .object = .empty });
        try capabilities.put(arena, "elicitation", .{ .object = modes });
    }
    if (client.options.roots != null) {
        var roots: ObjectMap = .empty;
        if (era == .legacy) try roots.put(arena, "listChanged", .{ .bool = true });
        try capabilities.put(arena, "roots", .{ .object = roots });
    }
    return .{ .object = capabilities };
}

/// A lost stream as a failure: `connection_lost`, naming `method`.
fn lostAs(slot: *Slot, err: AttemptError, method: []const u8) Error {
    return switch (err) {
        error.Lost => slot.fail(.{ .connection_lost = try slot.arena.print("The response stream of {s} broke", .{method}) }),
        else => |other| other,
    };
}

/// A request whose answer is complete; a stateless request whose stream broke is sent again with a new id.
pub fn request(client: *Client, slot: *Slot, method: []const u8, params: ObjectMap, given: Attempt) Error!ObjectMap {
    var reissues: usize = 0;
    while (true) : (reissues += 1) {
        const result = attempt(client, slot, method, params, given) catch |err| switch (err) {
            error.Lost => if (client.era() == .modern and reissues < protocol.reissues_max) continue else return lostAs(slot, err, method),
            else => |other| return other,
        };
        const kind = if (result.get("resultType")) |named| (if (named == .string) named.string else "") else "complete";
        if (std.mem.eql(u8, kind, "complete") or (std.mem.eql(u8, kind, "input_required") and protocol.takesInput(method))) return result;
        return slot.violated("The MCP server answered {s} with the result type {s}", .{ method, kind });
    }
}

/// A request a stateless server may answer `input_required`: the client gathers what it asks for, the person's answers
/// or its roots, and sends the request again with them and the server's `requestState`; where the request hands its
/// input back, a round that asks the person fails `input_required` instead. A request `answered` goes out with those
/// answers first.
pub fn requestWithInput(client: *Client, slot: *Slot, method: []const u8, params: ObjectMap, given: Attempt) Error!ObjectMap {
    var extra: ObjectMap = if (given.options.answered) |answered| try answers.inputParams(client, slot, answered) else .empty;
    var round: usize = 0;
    while (true) : (round += 1) {
        var sent = try params.clone(slot.arena);
        var it = extra.iterator();
        while (it.next()) |entry| try sent.put(slot.arena, entry.key_ptr.*, entry.value_ptr.*);
        const result = try request(client, slot, method, sent, given);
        const kind = result.get("resultType") orelse return result;
        if (kind != .string or !std.mem.eql(u8, kind.string, "input_required")) return result;
        if (round >= protocol.input_rounds_max) return slot.violated("The MCP server asked for input more than {d} times for {s}", .{ protocol.input_rounds_max, method });
        const input = try answers.inputRequired(client, slot, result);
        if (given.options.hand_back_input and input.asksPerson()) return slot.fail(.{ .input_required = .{ .method = method, .input = input } });
        extra = try answers.inputParams(client, slot, .{ .required = input, .answers = try answers.gathered(client, slot, input, given.options) });
    }
}

/// Sends one request and waits for its answer: its time, the server's questions on the way, its progress, or the
/// transport's end.
pub fn attempt(client: *Client, slot: *Slot, method: []const u8, params: ObjectMap, given: Attempt) AttemptError!ObjectMap {
    if (client.currentState() == .closed) return slot.fail(.{ .connection_lost = "The MCP client is not connected" });
    const id = client.nextId();
    const message: jsonrpc.Request = .{ .id = .{ .number = id }, .method = method, .params = try withMeta(client, slot.arena, params, id, given) };
    const timeout_ms = given.timeout_ms orelse given.options.timeout_ms orelse client.options.timeout_ms;
    const pending = try slot.arena.create(Pending);
    pending.* = .{ .id = id, .elicit = given.options.elicit };
    {
        client.lock.lockUncancelable(client.options.host.io);
        defer client.lock.unlock(client.options.host.io);
        try client.pending.append(client.gpa, pending);
    }
    defer forget(client, pending);
    const exchange = client.transport.request(slot, message, .{ .headers = given.headers, .idle_ms = if (timeout_ms == forever) null else timeout_ms }) catch |err| {
        if (slot.failure) |failure| if (failure == .session_ended) shut(client);
        return err;
    };
    var clock: Timing = .{ .client = client, .pending = pending, .timeout_ms = timeout_ms, .started_ms = client.options.host.nowMs() };
    clock.window_ms = clock.started_ms;
    while (true) {
        const wait = clock.left() orelse {
            exchange.cancel("Timed out");
            return slot.fail(.{ .timeout = .{ .method = method, .timeout_ms = timeout_ms } });
        };
        const incoming = exchange.next(slot, wait) catch |err| {
            if (slot.failure) |failure| if (failure == .canceled) exchange.cancel("Cancelled by the client") else exchange.close() else exchange.close();
            return err;
        };
        switch (incoming) {
            .message => |arrived| if (try received(client, slot, &clock, arrived.message, if (arrived.related) pending else null, given.options)) |answer| {
                exchange.close();
                return answer;
            },
            .quiet => if (clock.expired()) {
                exchange.cancel("Timed out");
                return slot.fail(.{ .timeout = .{ .method = method, .timeout_ms = timeout_ms } });
            },
            .lost => {
                exchange.close();
                return error.Lost;
            },
            .closed => |reason| {
                exchange.close();
                shut(client);
                return slot.fail(.{ .connection_lost = if (reason) |why| try slot.arena.print("The MCP connection closed: {s}", .{why}) else "The MCP connection closed" });
            },
        }
    }
}

/// What a message read for a request does: its answer, which ends the wait; its progress; or what the client
/// handles apart, the server's questions and notifications.
fn received(client: *Client, slot: *Slot, clock: *Timing, message: jsonrpc.Message, related: ?*Pending, options: RequestOptions) Error!?ObjectMap {
    const pending = clock.pending;
    switch (message) {
        .result => |result| if (result.id.eql(.{ .number = pending.id })) {
            if (result.result != .object) return slot.violated("The server answered with a result that is not an object", .{});
            return result.result.object;
        },
        .failure => |failed| if (failed.id) |id| if (id.eql(.{ .number = pending.id })) {
            return slot.fail(.{ .refused = .{ .code = failed.@"error".code, .message = failed.@"error".message, .data = failed.@"error".data } });
        },
        .notification => |notification| {
            if (progressOf(notification, pending.id)) |progress| {
                if (options.reset_timeout_on_progress) clock.restart(options.max_total_timeout_ms);
                if (options.progress) |handler| handler.progressed(handler.context, progress);
            } else try answers.notified(client, slot.arena, notification);
        },
        .request => |asked| try answers.serve(client, slot, asked, related),
    }
    return null;
}

/// The progress `notification` gives of the request `id`; null where it is of another.
fn progressOf(notification: jsonrpc.Notification, id: i64) ?types.Progress {
    if (!std.mem.eql(u8, notification.method, "notifications/progress")) return null;
    const params = notification.params orelse return null;
    if (params != .object) return null;
    const token = jsonrpc.Id.of(params.object.get("progressToken") orelse return null) orelse return null;
    if (!token.eql(.{ .number = id })) return null;
    const progress = results.numberOf(params.object.get("progress") orelse return null) orelse return null;
    const total = if (params.object.get("total")) |given| results.numberOf(given) else null;
    const text = if (params.object.get("message")) |given| (if (given == .string) given.string else null) else null;
    return .{ .progress = progress, .total = total, .message = text };
}

/// A request's time: how long it waits, from when its time last started, less what its questions waited.
const Timing = struct {
    client: *Client,
    pending: *Pending,
    timeout_ms: u64,
    started_ms: i64,
    /// When the time last started, and how long it had stood by then.
    window_ms: i64 = 0,
    stood_at_window_ms: i64 = 0,

    /// How long is left to wait, the time standing while a question waits; null where it ran out.
    fn left(timing: *Timing) ??u64 {
        if (timing.timeout_ms == forever) return @as(?u64, null);
        const now = timing.client.options.host.nowMs();
        timing.client.lock.lockUncancelable(timing.client.options.host.io);
        const standing = timing.pending.pauses > 0;
        const stood = timing.pending.stood(now);
        timing.client.lock.unlock(timing.client.options.host.io);
        // A question waits: the time stands, and the wait is looked at again in a while.
        if (standing) return timing.timeout_ms;
        const used: u64 = @intCast(@max(0, now - timing.window_ms - (stood - timing.stood_at_window_ms)));
        if (used >= timing.timeout_ms) return null;
        return timing.timeout_ms - used;
    }

    fn expired(timing: *Timing) bool {
        return timing.left() == null;
    }

    /// Starts the time again after progress, within the request's whole bound.
    fn restart(timing: *Timing, max_total_ms: ?u64) void {
        const now = timing.client.options.host.nowMs();
        timing.client.lock.lockUncancelable(timing.client.options.host.io);
        const stood = timing.pending.stood(now);
        timing.client.lock.unlock(timing.client.options.host.io);
        if (max_total_ms) |bound| if (now - timing.started_ms - stood >= @as(i64, @intCast(bound))) return;
        timing.window_ms = now;
        timing.stood_at_window_ms = stood;
    }
};

fn forget(client: *Client, pending: *Pending) void {
    client.lock.lockUncancelable(client.options.host.io);
    defer client.lock.unlock(client.options.host.io);
    for (client.pending.items, 0..) |each, index| if (each == pending) {
        _ = client.pending.swapRemove(index);
        return;
    };
}

/// The client closed with its transport: what waits fails as it reads its end.
pub fn shut(client: *Client) void {
    client.lock.lockUncancelable(client.options.host.io);
    defer client.lock.unlock(client.options.host.io);
    client.state = .closed;
}

/// `params` with the request's `_meta`: its progress token, and for a stateless request its version, the client and
/// its capabilities, and the log level it asks for.
pub fn withMeta(client: *Client, arena: Allocator, params: ObjectMap, id: i64, given: Attempt) Allocator.Error!?Value {
    var meta: ObjectMap = .empty;
    if (given.options.progress != null) try meta.put(arena, "progressToken", .{ .integer = id });
    const settled = client.server();
    const era = given.era orelse if (settled) |known| known.era else null;
    if (era == .modern) {
        const version = given.version orelse if (settled) |known| known.version else protocol.version;
        try meta.put(arena, protocol.meta.protocol_version, .{ .string = version });
        try meta.put(arena, protocol.meta.client_info, try foundation.json.toValue(arena, client.options.client));
        try meta.put(arena, protocol.meta.client_capabilities, try capabilitiesOf(client, arena, .modern));
        if (client.log_level) |level| try meta.put(arena, protocol.meta.log_level, .{ .string = @tagName(level) });
    }
    var sent = try params.clone(arena);
    if (meta.count() > 0) try sent.put(arena, "_meta", .{ .object = meta });
    return .{ .object = sent };
}

/// One page of the server's tools, each remembered for its headers and output schema; a tool whose `x-mcp-header`
/// annotations are invalid is left out and reported. The first page starts the tools remembered anew.
pub fn listTools(client: *Client, slot: *Slot, cursor: ?[]const u8, options: RequestOptions) Error!types.Page(types.Tool) {
    const tools = try page(types.Tool, client, slot, "tools/list", "tools", cursor, options);
    var kept: std.ArrayList(types.Tool) = .empty;
    client.lock.lockUncancelable(client.options.host.io);
    defer client.lock.unlock(client.options.host.io);
    if (cursor == null) {
        client.known.clearRetainingCapacity();
        _ = client.known_arena.reset(.retain_capacity);
    }
    for (tools.items) |*tool| {
        switch (try headers_.paramHeaders(slot.arena, &tool.inputSchema)) {
            .problem => |problem| client.report(try slot.arena.print("The MCP tool {s} is left out: {s}", .{ tool.name, problem })),
            .headers => |found| {
                try remember(client, tool.*, found);
                try kept.append(slot.arena, tool.*);
            },
        }
    }
    return .{ .items = kept.items, .nextCursor = tools.nextCursor };
}

/// Keeps a listed tool's headers and output schema, as long as the tools listed; the client's lock is held.
fn remember(client: *Client, tool: types.Tool, found: []const headers_.ParamHeader) Allocator.Error!void {
    const arena = client.known_arena.allocator();
    const headers = try arena.alloc(headers_.ParamHeader, found.len);
    for (found, headers) |header, *copy| {
        const path = try arena.alloc([]const u8, header.path.len);
        for (header.path, path) |key, *kept| kept.* = try arena.dupe(u8, key);
        copy.* = .{ .name = try arena.dupe(u8, header.name), .path = path };
    }
    const schema = if (tool.outputSchema) |given| try object.copied(arena, given) else null;
    try client.known.put(client.gpa, try arena.dupe(u8, tool.name), .{ .headers = headers, .output_schema = schema });
}

pub fn listed(comptime T: type, client: *Client, slot: *Slot, comptime method: []const u8, comptime field: []const u8, cursor: ?[]const u8, options: RequestOptions) Error!types.Page(T) {
    return page(T, client, slot, method, field, cursor, options);
}

fn page(comptime T: type, client: *Client, slot: *Slot, method: []const u8, comptime field: []const u8, cursor: ?[]const u8, options: RequestOptions) Error!types.Page(T) {
    var params: ObjectMap = .empty;
    if (cursor) |given| try params.put(slot.arena, "cursor", .{ .string = given });
    return results.page(T, slot, try request(client, slot, method, params, .{ .options = options }), field);
}

/// Every page's items, following `nextCursor`; a cursor that comes again is a protocol violation, not an endless loop.
pub fn allPages(comptime T: type, client: *Client, slot: *Slot, options: RequestOptions, comptime list: anytype) Error![]const T {
    var items: std.ArrayList(T) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var cursor: ?[]const u8 = null;
    while (true) {
        const next = try list(client, slot, cursor, options);
        try items.appendSlice(slot.arena, next.items);
        cursor = next.nextCursor orelse return items.items;
        if (seen.contains(cursor.?)) return slot.violated("The MCP server gave the same page cursor twice", .{});
        try seen.put(slot.arena, cursor.?, {});
    }
}

pub fn callTool(client: *Client, slot: *Slot, name: []const u8, arguments: ?Value, options: RequestOptions) Error!types.CallToolResult {
    const given = arguments orelse Value{ .object = .empty };
    var headers: []const Header = &.{};
    var schema: ?Value = null;
    {
        client.lock.lockUncancelable(client.options.host.io);
        defer client.lock.unlock(client.options.host.io);
        if (client.known.get(name)) |known| {
            headers = try headers_.paramHeaderValues(slot.arena, known.headers, given);
            if (known.output_schema) |output| schema = try object.copied(slot.arena, output);
        }
    }
    var params: ObjectMap = .empty;
    try params.put(slot.arena, "name", .{ .string = name });
    try params.put(slot.arena, "arguments", given);
    const result = try results.callToolResult(slot, try requestWithInput(client, slot, "tools/call", params, .{ .options = options, .headers = headers }));
    if (schema) |output| if (result.isError != true) {
        const content = result.structuredContent orelse return slot.violated("The MCP tool {s} has an output schema but returned no structured content", .{name});
        const problems = try typebox.problems(slot.arena, output, content);
        if (problems.len > 0) return slot.violated("The structured content of the MCP tool {s} does not match its output schema: {s}", .{ name, try typebox.shown(slot.arena, problems) });
    };
    return result;
}

pub fn readResource(client: *Client, slot: *Slot, uri: []const u8, options: RequestOptions) Error!types.ReadResourceResult {
    var params: ObjectMap = .empty;
    try params.put(slot.arena, "uri", .{ .string = uri });
    return results.readResourceResult(slot, try requestWithInput(client, slot, "resources/read", params, .{ .options = options }));
}

pub fn getPrompt(client: *Client, slot: *Slot, name: []const u8, arguments: []const [2][]const u8, options: RequestOptions) Error!types.GetPromptResult {
    var params: ObjectMap = .empty;
    try params.put(slot.arena, "name", .{ .string = name });
    try params.put(slot.arena, "arguments", try object.ofPairs(slot.arena, arguments));
    return results.getPromptResult(slot, try requestWithInput(client, slot, "prompts/get", params, .{ .options = options }));
}

pub fn complete(client: *Client, slot: *Slot, reference: types.CompletionReference, argument: [2][]const u8, context: []const [2][]const u8, options: RequestOptions) Error!types.CompleteResult {
    var params: ObjectMap = .empty;
    try params.put(slot.arena, "ref", try foundation.json.toValue(slot.arena, reference));
    var named: ObjectMap = .empty;
    try named.put(slot.arena, "name", .{ .string = argument[0] });
    try named.put(slot.arena, "value", .{ .string = argument[1] });
    try params.put(slot.arena, "argument", .{ .object = named });
    if (context.len > 0) {
        var given: ObjectMap = .empty;
        try given.put(slot.arena, "arguments", try object.ofPairs(slot.arena, context));
        try params.put(slot.arena, "context", .{ .object = given });
    }
    return results.completeResult(slot, try request(client, slot, "completion/complete", params, .{ .options = options }));
}

pub fn setLoggingLevel(client: *Client, slot: *Slot, level: types.LoggingLevel) Error!void {
    if (client.era() == .legacy) {
        var params: ObjectMap = .empty;
        try params.put(slot.arena, "level", .{ .string = @tagName(level) });
        _ = try request(client, slot, "logging/setLevel", params, .{});
        return;
    }
    client.lock.lockUncancelable(client.options.host.io);
    defer client.lock.unlock(client.options.host.io);
    client.log_level = level;
}

pub fn ping(client: *Client, slot: *Slot, options: RequestOptions) Error!void {
    if (client.era() != .legacy) return slot.violated("ping is not part of the stateless protocol ({s})", .{protocol.version});
    _ = try request(client, slot, "ping", .empty, .{ .options = options });
}

pub fn setRoots(client: *Client, slot: *Slot, roots: []const types.Root) Error!void {
    {
        client.lock.lockUncancelable(client.options.host.io);
        defer client.lock.unlock(client.options.host.io);
        client.roots = roots;
    }
    if (client.options.roots != null and client.era() == .legacy and client.currentState() == .connected) {
        try client.transport.send(slot, .{ .notification = .{ .method = "notifications/roots/list_changed" } });
    }
}
