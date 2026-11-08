//! The person's trust, asked by a fiber of a thread's: its request waiting on as the volume opens again, answered by the
//! person, recorded; and the asking of another thread, of the same configuration, ended by it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const Siphon = @import("Siphon.zig");
const threads = @import("threads.zig");
const trust = @import("tools.zig").trust;
const testing = @import("testing.zig");
const beak = @import("beak.zig");

const asked: trust.Asked = .{
    .folder = "/work/app",
    .path = "/work/app/.mcp.json",
    .digest = "d1",
    .servers = &.{.{ .name = "docs", .command = "docs-server" }},
};

/// Starts a fiber asking what `asked` asks in the thread `tid`, keyed by `key`.
fn startAsking(siphon: *Siphon, arena: Allocator, tid: []const u8, key: []const u8) !void {
    var changes: @import("runtime.zig").Changes = .{ .arena = arena };
    try changes.start(try threads.pathOf(arena, tid), key, trust.program, siphon.runtime.versionOf(trust.program).?, try foundation.json.encode(arena, asked), "");
    _ = try siphon.runtime.commit(&changes);
}

/// The key of the request the thread `tid`'s fiber `fiber` waits on, once it makes one.
fn askedOf(siphon: *Siphon, arena: Allocator, tid: []const u8, fiber: []const u8) ![]const u8 {
    const Waiting = struct {
        siphon: *Siphon,
        arena: Allocator,
        tid: []const u8,
        fiber: []const u8,

        fn key(waiting: *const @This()) ?[]const u8 {
            const state = threads.state(waiting.siphon.runtime, waiting.arena, waiting.tid) catch return null;
            for (state.processes) |process| {
                if (std.mem.eql(u8, process.key, waiting.fiber) and process.requests.len > 0) return process.requests[0].key;
            }
            return null;
        }

        fn made(waiting: *const @This()) bool {
            return waiting.key() != null;
        }
    };
    const waiting: Waiting = .{ .siphon = siphon, .arena = arena, .tid = tid, .fiber = fiber };
    try testing.pumpUntil(siphon, &waiting, Waiting.made);
    return waiting.key().?;
}

test "a trust request waits on as the volume opens again, by its key; answered, the decision ends another thread's asking" {
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const place = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path, "volume" });
    var first: []const u8 = undefined;
    var other: []const u8 = undefined;
    var before: []const u8 = undefined;
    {
        const siphon = try testing.open(&clock, .{ .directory = place });
        defer siphon.close();
        first = try threads.create(siphon.runtime, arena, .{}, "create-1");
        other = try threads.create(siphon.runtime, arena, .{}, "create-2");
        try startAsking(siphon, arena, first, "trust-a");
        try startAsking(siphon, arena, other, "trust-a");
        before = try askedOf(siphon, arena, first, "trust-a");
        _ = try askedOf(siphon, arena, other, "trust-a");
        // The state says what form the person's answer takes: the schema the runtime checks it against.
        for ((try threads.state(siphon.runtime, arena, first)).processes) |process| for (process.requests) |request| {
            if (std.mem.eql(u8, request.name, "trust")) try std.testing.expect(std.mem.indexOf(u8, request.answer.?.text, "\"trusted\"") != null);
        };
    }
    clock.now_ms += 1_000;
    const siphon = try testing.open(&clock, .{ .directory = place });
    defer siphon.close();
    // Its request waits on as the volume opened again, by the key the person was shown.
    try std.testing.expectEqualStrings(before, try askedOf(siphon, arena, first, "trust-a"));
    try std.testing.expect((try threads.answer(siphon.runtime, arena, first, before, .{ .text = "{\"trusted\":false}" })) == .given);
    try std.testing.expect((try testing.pumpUntilEnded(siphon, &arena, try beak.childPath(arena, try threads.pathOf(arena, first), "trust-a"))).status == .completed);
    try std.testing.expectEqual(@as(?bool, false), try trust.decided(siphon.runtime.volume, &arena, asked.folder, asked.digest));
    // The other thread's asking of the same ends with the decision, its request gone with it.
    try std.testing.expect((try testing.pumpUntilEnded(siphon, &arena, try beak.childPath(arena, try threads.pathOf(arena, other), "trust-a"))).status == .completed);
    // Another configuration of the folder is one the person has not decided on.
    try std.testing.expectEqual(@as(?bool, null), try trust.decided(siphon.runtime.volume, &arena, asked.folder, "d2"));
}
