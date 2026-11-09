//! What a server's handler reaches of the request it answers: the client's capabilities and log level, progress and
//! log messages sent to the client, and the client asked something. A question is asked by running the request again:
//! where its answer is not yet given, asking fails the handler with `Asked`, the server asks the client — `input_required`
//! to a stateless client, its own request to a session — and the handler runs again with the answers so far.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const typebox = @import("typebox");
const jsonrpc = @import("../jsonrpc.zig");
const protocol = @import("../protocol.zig");
const types = @import("../types.zig");

/// Where a server's messages go, JSON text one at a time; sent from any task, so it takes them one at a time.
pub const Peer = struct {
    context: *anyopaque,
    send: *const fn (context: *anyopaque, message: []const u8) void,
};

/// How a handler ends without its result: a question asked, the request refused with the error `Call.refusal` holds,
/// or the request cancelled.
pub const Error = Allocator.Error || error{ Asked, Refused, Canceled };

pub const Call = struct {
    /// Where everything of the request lives, until it is answered.
    arena: Allocator,
    era: protocol.Era,
    peer: Peer,
    progress_token: ?Value,
    /// The least severe log message the client takes; none, it takes none.
    log_level: ?types.LoggingLevel,
    capabilities: Value,
    /// The answers given so far, by the key of their question.
    answers: ObjectMap,
    asked: ?Asked = null,
    refusal: ?jsonrpc.ErrorObject = null,

    /// A question for the client: the key its answer goes under, the method asking it and its params.
    pub const Asked = struct { key: []const u8, method: []const u8, params: Value };

    /// Sends progress, where the request asked for it.
    pub fn progress(call: *Call, done: f64, total: ?f64, message: ?[]const u8) Allocator.Error!void {
        const token = call.progress_token orelse return;
        var params: ObjectMap = .empty;
        try params.put(call.arena, "progressToken", token);
        try params.put(call.arena, "progress", .{ .float = done });
        if (total) |given| try params.put(call.arena, "total", .{ .float = given });
        if (message) |given| try params.put(call.arena, "message", .{ .string = given });
        try call.notify("notifications/progress", .{ .object = params });
    }

    /// Sends a log message, where the client's level lets it through.
    pub fn log(call: *Call, level: types.LoggingLevel, logger: ?[]const u8, data: Value) Allocator.Error!void {
        const floor = call.log_level orelse return;
        if (@backingInt(level) < @backingInt(floor)) return;
        var params: ObjectMap = .empty;
        try params.put(call.arena, "level", .{ .string = @tagName(level) });
        if (logger) |name| try params.put(call.arena, "logger", .{ .string = name });
        try params.put(call.arena, "data", data);
        try call.notify("notifications/message", .{ .object = params });
    }

    /// The person's answer to `request`, asked under `key`. Refused where the client does not offer the request's
    /// mode, or answers with what does not fit it.
    pub fn elicit(call: *Call, key: []const u8, request: types.ElicitRequest) Error!types.ElicitResult {
        if (call.answers.get(key)) |answer| return call.elicitResult(key, request, answer);
        if (!offersElicitation(call.capabilities, request)) return call.refuse(call.missingCapability(), "The client does not offer {t} elicitation", .{std.meta.activeTag(request)});
        return call.ask(key, "elicitation/create", try elicitParams(call.arena, request));
    }

    /// The client's roots, asked under `key`; refused where the client offers none.
    pub fn roots(call: *Call, key: []const u8) Error![]const types.Root {
        if (call.answers.get(key)) |answer| return call.rootsOf(key, answer);
        if (!has(call.capabilities, "roots")) return call.refuse(call.missingCapability(), "The client does not offer roots", .{});
        return call.ask(key, "roots/list", .{ .object = .empty });
    }

    /// Refuses the request with a JSON-RPC error.
    pub fn refuse(call: *Call, code: i64, comptime text: []const u8, arguments: anytype) Error {
        call.refusal = .{ .code = code, .message = try call.arena.print(text, arguments) };
        return error.Refused;
    }

    fn ask(call: *Call, key: []const u8, method: []const u8, params: Value) Error {
        call.asked = .{ .key = try call.arena.dupe(u8, key), .method = method, .params = params };
        return error.Asked;
    }

    /// The error a client gets for a feature it does not offer: the current protocol's own code, else invalid params.
    fn missingCapability(call: *const Call) i64 {
        return if (call.era == .modern) protocol.codes.missing_required_client_capability else jsonrpc.codes.invalid_params;
    }

    fn notify(call: *Call, method: []const u8, params: Value) Allocator.Error!void {
        call.peer.send(call.peer.context, try (jsonrpc.Message{ .notification = .{ .method = method, .params = params } }).encode(call.arena));
    }

    fn elicitResult(call: *Call, key: []const u8, request: types.ElicitRequest, answer: Value) Error!types.ElicitResult {
        const action = if (answer == .object) answer.object.get("action") else null;
        const named = if (action) |given| (if (given == .string) given.string else "") else "";
        if (std.mem.eql(u8, named, "decline")) return .decline;
        if (std.mem.eql(u8, named, "cancel")) return .cancel;
        if (!std.mem.eql(u8, named, "accept")) return call.refuse(jsonrpc.codes.invalid_params, "The answer to {s} is no elicitation's", .{key});
        const form = switch (request) {
            .form => |form| form,
            .url => return .{ .accept = null },
        };
        const content = answer.object.get("content") orelse Value{ .object = .empty };
        const problems = try typebox.problems(call.arena, form.requestedSchema, content);
        if (problems.len > 0) return call.refuse(jsonrpc.codes.invalid_params, "The answer to {s} does not match its form: {s}", .{ key, try typebox.shown(call.arena, problems) });
        return .{ .accept = content };
    }

    fn rootsOf(call: *Call, key: []const u8, answer: Value) Error![]const types.Root {
        const listed = if (answer == .object) answer.object.get("roots") else null;
        const items = if (listed) |given| (if (given == .array) given.array.items else null) else null;
        const given = items orelse return call.refuse(jsonrpc.codes.invalid_params, "The answer to {s} lists no roots", .{key});
        const made = try call.arena.alloc(types.Root, given.len);
        for (given, made) |item, *root| {
            const uri = if (item == .object) item.object.get("uri") else null;
            if (uri == null or uri.? != .string) return call.refuse(jsonrpc.codes.invalid_params, "A root in the answer to {s} has no URI", .{key});
            const name = item.object.get("name");
            root.* = .{ .uri = uri.?.string, .name = if (name) |text| (if (text == .string) text.string else null) else null };
        }
        return made;
    }
};

/// Whether the client offers `request`'s mode: a link where it names `url`; a form where it names `form`, or names no
/// mode at all, as clients before modes did.
fn offersElicitation(capabilities: Value, request: types.ElicitRequest) bool {
    if (!has(capabilities, "elicitation")) return false;
    const modes = capabilities.object.get("elicitation").?;
    const named = modes == .object and (modes.object.get("form") != null or modes.object.get("url") != null);
    return switch (request) {
        .form => !named or modes.object.get("form") != null,
        .url => named and modes.object.get("url") != null,
    };
}

fn has(capabilities: Value, name: []const u8) bool {
    return capabilities == .object and capabilities.object.get(name) != null;
}

/// An elicitation's params as the protocol writes them; a form needs no mode, which clients before modes read.
fn elicitParams(arena: Allocator, request: types.ElicitRequest) Allocator.Error!Value {
    var params: ObjectMap = .empty;
    switch (request) {
        .form => |form| {
            try params.put(arena, "message", .{ .string = form.message });
            try params.put(arena, "requestedSchema", form.requestedSchema);
        },
        .url => |link| {
            try params.put(arena, "mode", .{ .string = "url" });
            try params.put(arena, "message", .{ .string = link.message });
            try params.put(arena, "url", .{ .string = link.url });
            if (link.elicitationId) |id| try params.put(arena, "elicitationId", .{ .string = id });
        },
    }
    return .{ .object = params };
}
