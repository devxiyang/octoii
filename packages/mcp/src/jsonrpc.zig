//! JSON-RPC 2.0, the messages MCP is spoken in: requests, notifications, results and errors, read from one JSON text —
//! one message or a batch — with their shape checked, and written back. Params and results stay JSON, which the
//! protocol's readers check where they read them.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const foundation = @import("foundation");

/// The codes of JSON-RPC 2.0's own errors.
pub const codes = struct {
    pub const parse_error = -32700;
    pub const invalid_request = -32600;
    pub const method_not_found = -32601;
    pub const invalid_params = -32602;
    pub const internal_error = -32603;
};

/// A request's id: a number or a string.
pub const Id = union(enum) {
    number: i64,
    string: []const u8,

    pub fn eql(a: Id, b: Id) bool {
        return switch (a) {
            .number => |number| b == .number and b.number == number,
            .string => |text| b == .string and std.mem.eql(u8, b.string, text),
        };
    }

    /// The id `value` is; null where it is none.
    pub fn of(value: Value) ?Id {
        return switch (value) {
            .integer => |number| .{ .number = number },
            .string => |text| .{ .string = text },
            else => null,
        };
    }

    pub fn jsonStringify(id: Id, writer: *std.json.Stringify) std.json.Stringify.Error!void {
        switch (id) {
            .number => |number| try writer.write(number),
            .string => |text| try writer.write(text),
        }
    }

    pub fn format(id: Id, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (id) {
            .number => |number| try writer.print("{d}", .{number}),
            .string => |text| try writer.writeAll(text),
        }
    }
};

/// What an error response carries: its code, its message, and its data where it has some.
pub const ErrorObject = struct {
    code: i64,
    message: []const u8,
    data: ?Value = null,
};

pub const Request = struct { id: Id, method: []const u8, params: ?Value = null };
pub const Notification = struct { method: []const u8, params: ?Value = null };
pub const Result = struct { id: Id, result: Value };
/// An error response, whose id is none where the request it answers could not be read.
pub const Failure = struct { id: ?Id, @"error": ErrorObject };

/// A message: a request, a notification, a result or an error.
pub const Message = union(enum) {
    request: Request,
    notification: Notification,
    result: Result,
    failure: Failure,

    /// The request a response answers; null for a request or a notification.
    pub fn answers(message: Message) ?Id {
        return switch (message) {
            .result => |result| result.id,
            .failure => |failure| failure.id,
            else => null,
        };
    }

    /// The message as JSON-RPC writes it.
    pub fn encode(message: Message, arena: Allocator) Allocator.Error![]const u8 {
        return switch (message) {
            .request => |request| foundation.json.encode(arena, .{ .jsonrpc = "2.0", .id = request.id, .method = request.method, .params = request.params }),
            .notification => |notification| foundation.json.encode(arena, .{ .jsonrpc = "2.0", .method = notification.method, .params = notification.params }),
            .result => |result| foundation.json.encode(arena, .{ .jsonrpc = "2.0", .id = result.id, .result = result.result }),
            // A failure without an id still writes it, as null.
            .failure => |failure| foundation.json.encode(arena, .{ .jsonrpc = "2.0", .id = if (failure.id) |id| idValue(id) else Value.null, .@"error" = failure.@"error" }),
        };
    }
};

fn idValue(id: Id) Value {
    return switch (id) {
        .number => |number| .{ .integer = number },
        .string => |text| .{ .string = text },
    };
}

pub const ParseError = Allocator.Error || error{NotJsonRpc};

/// The messages of one JSON text, one or a batch, in `arena`; `NotJsonRpc` for text that is not JSON-RPC 2.0.
pub fn parse(arena: Allocator, text: []const u8) ParseError![]const Message {
    const value = std.json.parseFromSliceLeaky(Value, arena, text, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotJsonRpc,
    };
    const given: []const Value = if (value == .array) value.array.items else &.{value};
    if (given.len == 0) return error.NotJsonRpc;
    const messages = try arena.alloc(Message, given.len);
    for (given, messages) |each, *message| message.* = messageOf(each) orelse return error.NotJsonRpc;
    return messages;
}

/// The one message `text` holds; `NotJsonRpc` where it holds none or a batch.
pub fn parseOne(arena: Allocator, text: []const u8) ParseError!Message {
    const messages = try parse(arena, text);
    if (messages.len != 1) return error.NotJsonRpc;
    return messages[0];
}

/// `value` as the message it is; null where it is none: params by position or by name, an id that is a number or a
/// string, a response with a result or an error but not both.
pub fn messageOf(value: Value) ?Message {
    if (value != .object) return null;
    const object = value.object;
    const version = object.get("jsonrpc") orelse return null;
    if (version != .string or !std.mem.eql(u8, version.string, "2.0")) return null;
    const params = object.get("params");
    if (params) |given| if (given != .object and given != .array) return null;
    if (object.get("method")) |method| {
        if (method != .string or object.contains("result") or object.contains("error")) return null;
        const id = object.get("id") orelse return .{ .notification = .{ .method = method.string, .params = params } };
        return .{ .request = .{ .id = Id.of(id) orelse return null, .method = method.string, .params = params } };
    }
    const given_id = object.get("id") orelse return null;
    if (object.get("result")) |result| {
        if (object.contains("error")) return null;
        return .{ .result = .{ .id = Id.of(given_id) orelse return null, .result = result } };
    }
    const failed = object.get("error") orelse return null;
    if (failed != .object) return null;
    const code = failed.object.get("code") orelse return null;
    const message = failed.object.get("message") orelse return null;
    if (code != .integer or message != .string) return null;
    const id: ?Id = if (given_id == .null) null else Id.of(given_id) orelse return null;
    return .{ .failure = .{ .id = id, .@"error" = .{ .code = code.integer, .message = message.string, .data = failed.object.get("data") } } };
}

test "messages are read with their shape checked, one or a batch, and written back" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const batch = try parse(a,
        \\[{"jsonrpc":"2.0","id":1,"method":"tools/list"},{"jsonrpc":"2.0","method":"notifications/initialized"},
        \\ {"jsonrpc":"2.0","id":"a","result":{"tools":[]}},{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}]
    );
    try std.testing.expectEqual(@as(usize, 4), batch.len);
    try std.testing.expectEqualStrings("tools/list", batch[0].request.method);
    try std.testing.expectEqual(.notification, std.meta.activeTag(batch[1]));
    try std.testing.expect(batch[2].answers().?.eql(.{ .string = "a" }));
    try std.testing.expectEqual(null, batch[3].failure.id);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}", try batch[0].encode(a));
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}", try batch[3].encode(a));
    for ([_][]const u8{
        "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"x\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":1.5,\"method\":\"x\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{},\"error\":{\"code\":1,\"message\":\"m\"}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"x\",\"params\":3}",
        "[]",
        "not json",
    }) |text| try std.testing.expectError(error.NotJsonRpc, parse(a, text));
}
