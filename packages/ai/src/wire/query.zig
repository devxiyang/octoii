//! A provider's own options as parameters of a query, for an API that takes its settings in its address, as Deepgram's
//! and xAI's speech-to-text do: a list as a parameter for each of its entries, a value as its text.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const Field = foundation.oauth.Field;

/// Appends `options` to `fields`; the name of the first option that is no text, number or boolean, where one is not,
/// as a query takes none of them.
pub fn appendOptions(arena: Allocator, fields: *std.ArrayList(Field), options: ?std.json.ObjectMap) Allocator.Error!?[]const u8 {
    const given = options orelse return null;
    var it = given.iterator();
    while (it.next()) |entry| {
        const values: []const std.json.Value = if (entry.value_ptr.* == .array) entry.value_ptr.array.items else &.{entry.value_ptr.*};
        for (values) |value| {
            const text = switch (value) {
                .string => |string| string,
                .integer, .float, .number_string, .bool => try foundation.json.encode(arena, value),
                else => return entry.key_ptr.*,
            };
            try fields.append(arena, .{ entry.key_ptr.*, text });
        }
    }
    return null;
}

test "options are parameters of a query, a list's entries each one, and an object none" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const options = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"diarize\":true,\"tag\":[\"a\",\"b\"],\"utt_split\":0.8}", .{});
    var fields: std.ArrayList(Field) = .empty;
    try std.testing.expectEqual(null, try appendOptions(arena, &fields, options.object));
    try std.testing.expectEqualStrings("diarize=true&tag=a&tag=b&utt_split=0.8", try foundation.oauth.formEncoded(arena, fields.items));
    const nested = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"extra\":{\"a\":1}}", .{});
    try std.testing.expectEqualStrings("extra", (try appendOptions(arena, &fields, nested.object)).?);
}
