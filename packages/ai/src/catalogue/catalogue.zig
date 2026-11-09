//! The catalogue built into ai: each driver's models — their facts and prices — as a versioned document, read once
//! when a `Models` begins.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const Model = @import("model.zig").Model;

/// The version of the catalogue document ai reads.
pub const version = 1;

const document = @embedFile("catalogue.json");

/// The models of the bundled catalogue, each under the driver its `octoii.provider` names, in `arena`.
pub fn bundled(arena: Allocator) Allocator.Error![]const Model {
    const parsed = foundation.json.decode(struct { version: u32, models: []const Model }, arena, document) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // The bundled document is checked by the tests below; it cannot fail to decode.
        else => unreachable,
    };
    std.debug.assert(parsed.version == version);
    return parsed.models;
}

test "the bundled catalogue decodes whole, every model of a provider and a kind" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const models = try bundled(arena_allocator.allocator());
    try std.testing.expect(models.len > 0);
    var described: usize = 0;
    var timed: usize = 0;
    for (models) |model| {
        try std.testing.expect(model.id.len > 0 and model.octoii.provider.len > 0 and model.octoii.kinds.len > 0);
        if (model.octoii.image_parameters != null) described += 1;
        if (model.supported_durations != null) timed += 1;
    }
    // The media facts are read with the others.
    try std.testing.expectEqual(@as(usize, 11), described);
    try std.testing.expectEqual(@as(usize, 6), timed);
}
