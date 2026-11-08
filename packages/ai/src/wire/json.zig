//! What the wires read of JSON that is not yet a type: an event's data before its type says which it is, and the
//! settings a request gives one provider under `provider.options`, which only that provider knows the shape of.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const vocabulary = @import("vocabulary");
const failure_ = @import("../failure.zig");
const Error = failure_.Error;
const Call = @import("../driver.zig").Call;

/// The settings a request gives the provider `id` under `provider.options`, its members to set over the provider's
/// request; null where it gives none.
pub fn ownOptions(arena: Allocator, request: *const vocabulary.ResponsesRequest, id: []const u8) Allocator.Error!?std.json.ObjectMap {
    const preferences = request.provider orelse return null;
    return optionsOf(arena, preferences.options, id);
}

/// The settings `options`, a request's provider options, give the provider `id`; null where they give none.
pub fn optionsOf(arena: Allocator, given: ?@import("foundation").json.Raw, id: []const u8) Allocator.Error!?std.json.ObjectMap {
    const options = given orelse return null;
    const parsed = std.json.parseFromSliceLeaky(Value, arena, options.text, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Raw JSON holds what parses; anything else is no options.
        else => return null,
    };
    if (parsed != .object) return null;
    const own = parsed.object.get(id) orelse return null;
    return if (own == .object) own.object else null;
}

/// The text of a member of an object; null where it is absent or not text.
pub fn textOf(value: Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const member = value.object.get(key) orelse return null;
    return if (member == .string) member.string else null;
}

/// An event's data read as a JSON object of a type; `invalid_response` where it is not.
pub fn parseObject(call: *Call, data: []const u8) Error!Value {
    const value = std.json.parseFromSliceLeaky(Value, call.arena, data, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    if (value) |given| if (textOf(given, "type") != null) return given;
    var failure: failure_.Failure = .init(.invalid_response, "The provider sent an event that is no JSON object of a type");
    failure.body = data;
    return call.fail(failure);
}

/// A request's `provider` — its preferences, or its data policy — held to `id`'s own options, which its provider's
/// media APIs take: those options; `Failed`, naming any other field, as `refused` begins saying, where it sets one.
pub fn ownOptionsAlone(call: *Call, provider: anytype, id: []const u8, comptime refused: []const u8) Error!?std.json.ObjectMap {
    const given = provider orelse return null;
    var others: std.ArrayList([]const u8) = .empty;
    inline for (comptime std.meta.fieldNames(@TypeOf(given))) |name| {
        if (comptime !std.mem.eql(u8, name, "options")) if (@field(given, name) != null) try others.append(call.arena, name);
    }
    if (others.items.len > 0) return call.failWith(.invalid_request, refused, .{try std.mem.join(call.arena, ", ", others.items)});
    return optionsOf(call.arena, given.options, id);
}
