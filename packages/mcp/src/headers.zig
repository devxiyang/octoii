//! The values Streamable HTTP mirrors from a request's body into headers: `Mcp-Name`, and the `Mcp-Param-{name}` of a
//! tool's arguments whose schema property carries `x-mcp-header`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const foundation = @import("foundation");
const Header = foundation.http.Header;

/// `value` as a header's value: as it is where it is visible ASCII with inner spaces, else — non-ASCII, control
/// characters, surrounding whitespace, or text that looks encoded — the base64 of its UTF-8 between `=?base64?` and
/// `?=`.
pub fn headerValue(arena: Allocator, value: []const u8) Allocator.Error![]const u8 {
    if (isPlain(value)) return value;
    const encoder = std.base64.standard.Encoder;
    const encoded = try arena.alloc(u8, encoder.calcSize(value.len));
    return arena.print("=?base64?{s}?=", .{encoder.encode(encoded, value)});
}

/// A header's value as it was before `headerValue`: its base64 decoded where it is so encoded.
pub fn decodedValue(arena: Allocator, value: []const u8) Allocator.Error![]const u8 {
    if (!looksEncoded(value)) return value;
    const inner = value["=?base64?".len .. value.len - "?=".len];
    const decoder = std.base64.standard.Decoder;
    const bytes = try arena.alloc(u8, decoder.calcSizeForSlice(inner) catch return value);
    decoder.decode(bytes, inner) catch return value;
    return bytes;
}

fn isPlain(value: []const u8) bool {
    if (value.len == 0 or looksEncoded(value)) return false;
    if (!isVisible(value[0]) or !isVisible(value[value.len - 1])) return false;
    for (value) |char| if (!(isVisible(char) or char == ' ' or char == '\t')) return false;
    return true;
}

fn isVisible(char: u8) bool {
    return char >= 0x21 and char <= 0x7e;
}

fn looksEncoded(value: []const u8) bool {
    return value.len >= "=?base64??=".len and std.mem.startsWith(u8, value, "=?base64?") and std.mem.endsWith(u8, value, "?=");
}

/// An `x-mcp-header` annotation: the header's name part, and the chain of `properties` keys to the argument.
pub const ParamHeader = struct { name: []const u8, path: []const []const u8 };

/// A tool's `x-mcp-header` annotations, or why they make it invalid.
pub const ParamHeaders = union(enum) {
    headers: []const ParamHeader,
    problem: []const u8,
};

/// The tool's `x-mcp-header` annotations, or why they make the tool invalid: a name that is no header token or comes
/// twice, an annotation on a property that is no integer, string or boolean, or one not reached through `properties`
/// alone.
pub fn paramHeaders(arena: Allocator, input_schema: *const Value) Allocator.Error!ParamHeaders {
    var collector: Collector = .{ .arena = arena };
    if (try collector.collect(input_schema, &.{})) |problem| return .{ .problem = problem };
    if (collector.unreachableAnnotation(input_schema, false)) |problem| return .{ .problem = problem };
    return .{ .headers = collector.headers.items };
}

const Collector = struct {
    arena: Allocator,
    headers: std.ArrayList(ParamHeader) = .empty,
    /// The schemas reached through `properties` alone.
    reached: std.AutoHashMapUnmanaged(*const Value, void) = .empty,

    fn collect(collector: *Collector, schema: *const Value, path: []const []const u8) Allocator.Error!?[]const u8 {
        if (schema.* != .object) return null;
        try collector.reached.put(collector.arena, schema, {});
        const properties = schema.object.getPtr("properties") orelse return null;
        if (properties.* != .object) return null;
        var it = properties.object.iterator();
        while (it.next()) |entry| {
            const property = entry.value_ptr;
            if (property.* != .object) continue;
            const key = entry.key_ptr.*;
            const at = try collector.arena.alloc([]const u8, path.len + 1);
            @memcpy(at[0..path.len], path);
            at[path.len] = key;
            if (property.object.get("x-mcp-header")) |name| {
                if (try collector.annotation(name, property.object.get("type"), key, at)) |problem| return problem;
            }
            if (try collector.collect(property, at)) |problem| return problem;
        }
        return null;
    }

    fn annotation(collector: *Collector, name: Value, kind: ?Value, key: []const u8, path: []const []const u8) Allocator.Error!?[]const u8 {
        if (name != .string or !isToken(name.string)) return try collector.arena.print("x-mcp-header {s} of {s} is not a header name", .{ try foundation.json.encode(collector.arena, name), key });
        const typed = if (kind) |given| given == .string and (std.mem.eql(u8, given.string, "string") or std.mem.eql(u8, given.string, "integer") or std.mem.eql(u8, given.string, "boolean")) else false;
        if (!typed) return try collector.arena.print("x-mcp-header {s} is on {s}, which is not a string, integer or boolean", .{ name.string, key });
        for (collector.headers.items) |header| if (std.ascii.eqlIgnoreCase(header.name, name.string)) {
            return try collector.arena.print("x-mcp-header {s} appears twice", .{name.string});
        };
        try collector.headers.append(collector.arena, .{ .name = name.string, .path = path });
        return null;
    }

    /// An `x-mcp-header` anywhere but on a property reached through `properties` alone, such as under `items` or
    /// `anyOf`.
    fn unreachableAnnotation(collector: *Collector, value: *const Value, in_properties: bool) ?[]const u8 {
        switch (value.*) {
            .array => |array| for (array.items) |*item| if (collector.unreachableAnnotation(item, false)) |problem| return problem,
            .object => |object| {
                if (!in_properties and !collector.reached.contains(value) and object.contains("x-mcp-header")) {
                    return "x-mcp-header is on a property not reached through properties alone";
                }
                var it = object.iterator();
                while (it.next()) |entry| {
                    const into_properties = std.mem.eql(u8, entry.key_ptr.*, "properties") and !in_properties;
                    if (collector.unreachableAnnotation(entry.value_ptr, into_properties)) |problem| return problem;
                }
            },
            else => {},
        }
        return null;
    }
};

/// Whether `name` is an RFC 9110 token, as a header's name is.
fn isToken(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |char| {
        const allowed = std.ascii.isAlphanumeric(char) or std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", char) != null;
        if (!allowed) return false;
    }
    return true;
}

/// The `Mcp-Param-{name}` headers of a call's arguments; an argument absent or null has none.
pub fn paramHeaderValues(arena: Allocator, headers: []const ParamHeader, arguments: Value) Allocator.Error![]const Header {
    var values: std.ArrayList(Header) = .empty;
    for (headers) |header| {
        var at = arguments;
        const found = for (header.path) |key| {
            if (at != .object) break false;
            at = at.object.get(key) orelse break false;
        } else true;
        if (!found) continue;
        const text: ?[]const u8 = switch (at) {
            .string => |string| try headerValue(arena, string),
            .bool => |flag| if (flag) "true" else "false",
            .integer => |integer| try arena.print("{d}", .{integer}),
            else => null,
        };
        if (text) |given| try values.append(arena, .{ .name = try arena.print("Mcp-Param-{s}", .{header.name}), .value = given });
    }
    return values.items;
}

fn parsed(arena: Allocator, text: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, text, .{});
}

test "a header's value is as it is where it is plain, else its UTF-8 as base64" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    try std.testing.expectEqualStrings("search the web", try headerValue(arena, "search the web"));
    try std.testing.expectEqualStrings("=?base64?IGxlYWRpbmc=?=", try headerValue(arena, " leading"));
    try std.testing.expectEqualStrings("=?base64?w6l0w6k=?=", try headerValue(arena, "été"));
    try std.testing.expectEqualStrings("=?base64?PT9iYXNlNjQ/eD89?=", try headerValue(arena, "=?base64?x?="));
    try std.testing.expectEqualStrings("été", try decodedValue(arena, "=?base64?w6l0w6k=?="));
}

test "a tool's x-mcp-header annotations become its arguments' headers, and an invalid one is why the tool is left out" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const schema = try parsed(arena,
        \\{"type":"object","properties":{"region":{"type":"string","x-mcp-header":"Region"},
        \\ "options":{"type":"object","properties":{"dry":{"type":"boolean","x-mcp-header":"Dry-Run"}}},"count":{"type":"integer","x-mcp-header":"Count"}}}
    );
    const headers = (try paramHeaders(arena, &schema)).headers;
    try std.testing.expectEqual(@as(usize, 3), headers.len);
    const values = try paramHeaderValues(arena, headers, try parsed(arena, "{\"region\":\"eu west\",\"options\":{\"dry\":true},\"count\":null}"));
    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expectEqualStrings("Mcp-Param-Region", values[0].name);
    try std.testing.expectEqualStrings("eu west", values[0].value);
    try std.testing.expectEqualStrings("true", values[1].value);
    for ([_]struct { []const u8, []const u8 }{
        .{ "{\"properties\":{\"a\":{\"type\":\"string\",\"x-mcp-header\":\"Bad Name\"}}}", "x-mcp-header \"Bad Name\" of a is not a header name" },
        .{ "{\"properties\":{\"a\":{\"type\":\"number\",\"x-mcp-header\":\"A\"}}}", "x-mcp-header A is on a, which is not a string, integer or boolean" },
        .{ "{\"properties\":{\"a\":{\"type\":\"string\",\"x-mcp-header\":\"A\"},\"b\":{\"type\":\"string\",\"x-mcp-header\":\"a\"}}}", "x-mcp-header a appears twice" },
        .{ "{\"properties\":{\"a\":{\"type\":\"array\",\"items\":{\"type\":\"string\",\"x-mcp-header\":\"A\"}}}}", "x-mcp-header is on a property not reached through properties alone" },
    }) |case| {
        const given = try parsed(arena, case[0]);
        try std.testing.expectEqualStrings(case[1], (try paramHeaders(arena, &given)).problem);
    }
}
