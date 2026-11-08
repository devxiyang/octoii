//! What a server reads of a request and writes of its answers, apart from what it does with them.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const foundation = @import("foundation");
const jsonrpc = @import("../jsonrpc.zig");
const protocol = @import("../protocol.zig");
const types = @import("../types.zig");

pub fn paramsOf(request: jsonrpc.Request) ObjectMap {
    const params = request.params orelse return .empty;
    return if (params == .object) params.object else .empty;
}

pub fn metaOf(params: ObjectMap) ObjectMap {
    const meta = params.get("_meta") orelse return .empty;
    return if (meta == .object) meta.object else .empty;
}

pub fn stringOf(value: ?Value) ?[]const u8 {
    const given = value orelse return null;
    return if (given == .string) given.string else null;
}

/// The stateless version a request names in its metadata, which makes it a request of the current protocol.
pub fn modernVersion(params: ObjectMap) ?[]const u8 {
    return stringOf(metaOf(params).get(protocol.meta.protocol_version));
}

pub fn isModernVersion(version: []const u8) bool {
    for (protocol.modern_versions) |each| if (std.mem.eql(u8, each, version)) return true;
    return false;
}

/// A result as the request's era writes it: a stateless one says it is complete.
pub fn complete(arena: Allocator, era: protocol.Era, result: Value) Allocator.Error!Value {
    if (era == .legacy) return result;
    var made = try result.object.clone(arena);
    try made.put(arena, "resultType", .{ .string = "complete" });
    return .{ .object = made };
}

/// Where a list's page starts: its cursor, an offset the server gave; null for a cursor it did not give.
pub fn cursorOf(params: ObjectMap) ?usize {
    const cursor = params.get("cursor") orelse return 0;
    if (cursor == .null) return 0;
    if (cursor != .string) return null;
    return std.fmt.parseInt(usize, cursor.string, 10) catch null;
}

/// The page of `items` from `start`, `size` long where the server pages its lists, under `field`, with the next
/// page's cursor where there is one.
pub fn page(arena: Allocator, items: anytype, start: usize, size: ?usize, field: []const u8) Allocator.Error!Value {
    const from = @min(start, items.len);
    const end = @min(from + (size orelse items.len), items.len);
    var result: ObjectMap = .empty;
    try result.put(arena, field, try foundation.json.toValue(arena, items[from..end]));
    if (end < items.len) try result.put(arena, "nextCursor", .{ .string = try std.fmt.allocPrint(arena, "{d}", .{end}) });
    return .{ .object = result };
}

/// The answers a stateless request brings: those its `requestState` keeps, and its `inputResponses`.
pub fn givenAnswers(arena: Allocator, params: ObjectMap) Allocator.Error!ObjectMap {
    var answers: ObjectMap = .empty;
    if (stringOf(params.get("requestState"))) |state| {
        const kept = std.json.parseFromSliceLeaky(Value, arena, state, .{ .allocate = .alloc_always }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => Value{ .object = .empty },
        };
        if (kept == .object) answers = try kept.object.clone(arena);
    }
    if (params.get("inputResponses")) |responses| if (responses == .object) {
        var it = responses.object.iterator();
        while (it.next()) |entry| try answers.put(arena, entry.key_ptr.*, entry.value_ptr.*);
    };
    return answers;
}

/// A stateless request's `input_required` answer: the question under its key, and the answers so far kept in its
/// `requestState`, which the client sends back.
pub fn inputRequired(arena: Allocator, key: []const u8, method: []const u8, params: Value, answers: ObjectMap) Allocator.Error!Value {
    var question: ObjectMap = .empty;
    try question.put(arena, "method", .{ .string = method });
    try question.put(arena, "params", params);
    var requests: ObjectMap = .empty;
    try requests.put(arena, key, .{ .object = question });
    var result: ObjectMap = .empty;
    try result.put(arena, "resultType", .{ .string = "input_required" });
    try result.put(arena, "inputRequests", .{ .object = requests });
    try result.put(arena, "requestState", .{ .string = try foundation.json.encode(arena, Value{ .object = answers }) });
    return .{ .object = result };
}

/// `params` with the subscription `id` in its metadata.
pub fn subscribed(arena: Allocator, params: ?ObjectMap, id: jsonrpc.Id) Allocator.Error!Value {
    var made: ObjectMap = if (params) |given| try given.clone(arena) else .empty;
    var meta: ObjectMap = .empty;
    try meta.put(arena, protocol.meta.subscription_id, idValue(id));
    try made.put(arena, "_meta", .{ .object = meta });
    return .{ .object = made };
}

pub fn idValue(id: jsonrpc.Id) Value {
    return switch (id) {
        .number => |number| .{ .integer = number },
        .string => |text| .{ .string = text },
    };
}

/// The refusal of a version the server does not speak, naming those it does.
pub fn unsupportedVersion(arena: Allocator, requested: []const u8, speaks_legacy: bool) Allocator.Error!jsonrpc.ErrorObject {
    var supported = std.json.Array.init(arena);
    for (protocol.modern_versions) |each| try supported.append(.{ .string = each });
    if (speaks_legacy) for (protocol.legacy_versions) |each| try supported.append(.{ .string = each });
    var data: ObjectMap = .empty;
    try data.put(arena, "supported", .{ .array = supported });
    try data.put(arena, "requested", .{ .string = requested });
    return .{ .code = protocol.codes.unsupported_protocol_version, .message = "Unsupported protocol version", .data = .{ .object = data } };
}

/// `message` copied into `arena`, so that it outlives the text it was read from.
pub fn copied(arena: Allocator, message: jsonrpc.Message) Allocator.Error!jsonrpc.Message {
    return jsonrpc.parseOne(arena, try message.encode(arena)) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // What was just encoded reads back.
        error.NotJsonRpc => unreachable,
    };
}

pub fn loggingLevel(value: ?Value) ?types.LoggingLevel {
    return std.meta.stringToEnum(types.LoggingLevel, stringOf(value) orelse return null);
}
