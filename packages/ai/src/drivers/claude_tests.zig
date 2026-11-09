//! Claude through the agent gateway: its models as the gateway lists them, its standing as the gateway answers, and a
//! text request sent to the gateway as Anthropic's API takes one, with no key — the recorded Anthropic exchange
//! replayed at the gateway's address.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const http = foundation.http;
const vocabulary = @import("vocabulary");
const seam = @import("../driver.zig");
const Models = @import("../Models.zig");
const fixtures = @import("../testing/fixtures.zig");
const TestHost = @import("../testing/host.zig").Host;
const claude = @import("claude.zig");

/// The gateway, answering its listing of models where it answers at all; each request it is sent kept, by its address
/// and whether it carried a key.
const Gateway = struct {
    arena: Allocator,
    listing: ?[]const u8,
    rest: ?http.Http = null,
    asked: std.ArrayList([]const u8) = .empty,

    fn network(gateway: *Gateway) http.Http {
        return .{ .context = gateway, .vtable = &.{ .send = send } };
    }

    fn send(context: *anyopaque, request: http.Request) http.SendError!http.Response {
        const gateway: *Gateway = @ptrCast(@alignCast(context));
        const keyed = http.find(request.headers, "x-api-key") != null;
        try gateway.asked.append(gateway.arena, try gateway.arena.print("{s}{s}", .{ request.url, if (keyed) " keyed" else "" }));
        if (std.mem.eql(u8, request.url, claude.base_url ++ "/models")) {
            const listed = gateway.listing orelse return error.Transport;
            const reader = try gateway.arena.create(foundation.replay.ChunkReader);
            reader.* = .init(try gateway.arena.dupe([]const u8, &.{listed}), try gateway.arena.alloc(u8, 4096));
            const headers = try gateway.arena.dupe(http.Header, &.{.{ .name = "content-type", .value = "application/json" }});
            return .{ .status = 200, .headers = headers, .body = &reader.reader, .context = reader, .vtable = &.{ .failure = failure, .close = close } };
        }
        if (gateway.rest) |rest| return rest.send(request);
        return error.Transport;
    }

    fn failure(_: *anyopaque) http.Error {
        return error.Transport;
    }

    fn close(_: *anyopaque) void {}
};

const opus_and_sonnet =
    \\{"data":[{"type":"model","id":"claude-opus-5-5","display_name":"Opus 5.5","created_at":"1970-01-01T00:00:00Z"},
    \\ {"type":"model","id":"sonnet","display_name":"Sonnet","created_at":"1970-01-01T00:00:00Z"}],"has_more":false}
;

fn modelsOver(arena: Allocator, gateway: *Gateway) !*Models {
    const test_host = try arena.create(TestHost);
    test_host.* = .{};
    const providers = try arena.dupe(seam.Provider, &.{.{ .id = "claude", .name = "Claude", .driver = &claude.driver }});
    return Models.init(arena, .{ .providers = providers, .host = test_host.host(gateway.network()) });
}

test "Claude's models are those the gateway lists, costing nothing, and it stands connected where the gateway answers" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var gateway: Gateway = .{ .arena = arena, .listing = opus_and_sonnet };
    const models = try modelsOver(arena, &gateway);
    try models.refresh();
    const opus = (try models.find(arena, "claude/claude-opus-5-5")).?.model;
    try std.testing.expectEqualStrings("Opus 5.5", opus.name);
    try std.testing.expectEqualStrings("0", opus.pricing.?.prompt);
    try std.testing.expect(try models.find(arena, "claude/sonnet") != null);
    try std.testing.expect((try models.status(arena, "claude")).connected);
    var absent: Gateway = .{ .arena = arena, .listing = null };
    const none = try (try modelsOver(arena, &absent)).status(arena, "claude");
    try std.testing.expect(!none.connected);
    try std.testing.expectEqualStrings("No server answers with its models at gateway://claude/v1/models", none.problem.?);
}

test "a text request goes to the gateway as Anthropic's API takes it, carrying no key" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const fixture = try fixtures.load(arena, "anthropic", "text");
    const exchanges = try arena.dupe(foundation.replay.Exchange, fixture.exchanges);
    for (exchanges) |*exchange| exchange.request.url = claude.base_url ++ "/messages";
    var replay: foundation.replay.Replay = .init(arena, exchanges);
    var gateway: Gateway = .{ .arena = arena, .listing = opus_and_sonnet, .rest = replay.http() };
    const models = try modelsOver(arena, &gateway);
    try models.refresh();
    var request = fixture.request;
    request.model = "claude/claude-opus-5-5";
    const response = try models.create(arena, request);
    if (replay.mismatch) |why| std.debug.print("{s}\n", .{why});
    try std.testing.expectEqual(vocabulary.response.ResponseStatus.completed, response.status);
    try std.testing.expectEqual(@as(usize, 0), replay.unused().len);
    try std.testing.expectEqualStrings(claude.base_url ++ "/messages", gateway.asked.items[gateway.asked.items.len - 1]);
}
