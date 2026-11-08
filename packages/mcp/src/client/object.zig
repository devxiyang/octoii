//! JSON values as the client builds and keeps them.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const foundation = @import("foundation");

/// `value` copied into `arena`, as what outlives the reading it came from.
pub fn copied(arena: Allocator, value: Value) Allocator.Error!Value {
    return foundation.json.toValue(arena, value);
}

/// An object of string members, from name and value pairs.
pub fn ofPairs(arena: Allocator, pairs: []const [2][]const u8) Allocator.Error!Value {
    var made: std.json.ObjectMap = .empty;
    for (pairs) |pair| try made.put(arena, pair[0], .{ .string = pair[1] });
    return .{ .object = made };
}
