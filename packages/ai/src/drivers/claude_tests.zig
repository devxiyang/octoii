//! Claude through the agent gateway: its models as the gateway lists them, its standing as the account the gateway
//! tells Claude Code is signed in as, and a text request sent to the gateway as Anthropic's API takes one, with no key —
//! the recorded Anthropic exchange replayed at the gateway's address — naming its conversation, which ends there too.
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

/// The gateway, answering its listing of models where it answers at all, and what it is asked to delete — a
/// conversation ended, an account removed — where it is told to; each request it is sent kept, by its address and
/// whether it carried a key, and the conversation a request named.
const Gateway = struct {
    arena: Allocator,
    listing: ?[]const u8,
    rest: ?http.Http = null,
    /// Whether it deletes what it is asked to.
    deletes: bool = false,
    /// The account Claude Code is signed in as; none, not signed in.
    account: ?[]const u8 = null,
    /// Whether the plan's five hours are used up, till the time it names, in seconds since the epoch.
    used_up_till: ?[]const u8 = null,
    asked: std.ArrayList([]const u8) = .empty,
    conversation: ?[]const u8 = null,

    fn network(gateway: *Gateway) http.Http {
        return .{ .context = gateway, .vtable = &.{ .send = send } };
    }

    fn send(context: *anyopaque, request: http.Request) http.SendError!http.Response {
        const gateway: *Gateway = @ptrCast(@alignCast(context));
        const keyed = http.find(request.headers, "x-api-key") != null;
        if (http.find(request.headers, claude.conversation_header)) |named| gateway.conversation = try gateway.arena.dupe(u8, named);
        if (request.method == .DELETE) {
            try gateway.asked.append(gateway.arena, try gateway.arena.print("DELETE {s}", .{request.url}));
            if (!gateway.deletes) return error.Transport;
            return answered(gateway, 204, "");
        }
        try gateway.asked.append(gateway.arena, try gateway.arena.print("{s}{s}", .{ request.url, if (keyed) " keyed" else "" }));
        if (std.mem.endsWith(u8, request.url, "/v1/models")) return answered(gateway, 200, gateway.listing orelse return error.Transport);
        if (std.mem.endsWith(u8, request.url, "/v1/login")) return answered(gateway, 200,
            \\{"argv":["/usr/local/bin/claude","auth","login"],"environment":[{"name":"CLAUDE_CONFIG_DIR","value":"/state/accounts/a/logins/claude"}]}
        );
        if (std.mem.endsWith(u8, request.url, "/v1/account")) {
            if (gateway.account) |account| return answered(gateway, 200, account);
            return answered(gateway, 401, "{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"Claude Code is not signed in on this computer: run `claude` and sign in.\"}}");
        }
        if (gateway.used_up_till) |reset| if (std.mem.endsWith(u8, request.url, "/v1/messages")) {
            const headers = try gateway.arena.dupe(http.Header, &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "anthropic-ratelimit-unified-status", .value = "rejected" },
                .{ .name = "anthropic-ratelimit-unified-reset", .value = reset },
                .{ .name = "anthropic-ratelimit-unified-representative-claim", .value = "five_hour" },
            });
            const reader = try gateway.arena.create(foundation.replay.ChunkReader);
            const said = "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"Claude's five-hour limit is used up.\"}}";
            reader.* = .init(try gateway.arena.dupe([]const u8, &.{said}), try gateway.arena.alloc(u8, 4096));
            return .{ .status = 429, .headers = headers, .body = &reader.reader, .context = reader, .vtable = &.{ .failure = failure, .close = close } };
        };
        if (gateway.rest) |rest| return rest.send(request);
        return error.Transport;
    }

    fn answered(gateway: *Gateway, status: u16, body: []const u8) http.SendError!http.Response {
        const reader = try gateway.arena.create(foundation.replay.ChunkReader);
        reader.* = .init(try gateway.arena.dupe([]const u8, &.{body}), try gateway.arena.alloc(u8, 4096));
        const headers = try gateway.arena.dupe(http.Header, &.{.{ .name = "content-type", .value = "application/json" }});
        return .{ .status = status, .headers = headers, .body = &reader.reader, .context = reader, .vtable = &.{ .failure = failure, .close = close } };
    }

    fn failure(_: *anyopaque) http.Error {
        return error.Transport;
    }

    fn close(_: *anyopaque) void {}
};

const opus_and_sonnet =
    \\{"data":[{"type":"model","id":"claude-opus-5-5","display_name":"Opus 5.5","created_at":"1970-01-01T00:00:00Z","max_input_tokens":1000000},
    \\ {"type":"model","id":"sonnet","display_name":"Sonnet","created_at":"1970-01-01T00:00:00Z"}],"has_more":false}
;

fn modelsOver(arena: Allocator, gateway: *Gateway) !*Models {
    const test_host = try arena.create(TestHost);
    test_host.* = .{};
    const providers = try arena.dupe(seam.Provider, &.{.{ .id = "claude", .name = "Claude", .driver = &claude.driver }});
    return Models.init(arena, .{ .providers = providers, .host = test_host.host(gateway.network()) });
}

test "Claude's models are those the gateway lists, in the window Claude Code gives each, costing nothing, and it stands connected as Claude Code is signed in" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var gateway: Gateway = .{ .arena = arena, .listing = opus_and_sonnet, .account =
        \\{"email":"person@example.com","organization":null,"subscription_type":"max",
        \\ "limits":[{"window_minutes":300,"scope":null,"used_percent":40,"resets_at_ms":1762750800000},
        \\  {"window_minutes":10080,"scope":"Opus","used_percent":12.5,"resets_at_ms":null}]}
    };
    const models = try modelsOver(arena, &gateway);
    try models.refresh();
    const opus = (try models.find(arena, "claude/claude-opus-5-5")).?.model;
    try std.testing.expectEqualStrings("Opus 5.5", opus.name);
    try std.testing.expectEqualStrings("0", opus.pricing.?.prompt);
    try std.testing.expectEqual(@as(?u64, 1_000_000), opus.context_length);
    // A model whose window Claude Code did not tell is taken to have the window assumed of any.
    try std.testing.expectEqual(@as(?u64, 200_000), (try models.find(arena, "claude/sonnet")).?.model.context_length);
    const signed_in = try models.status(arena, "claude");
    try std.testing.expect(signed_in.connected);
    try std.testing.expectEqualStrings("person@example.com (max)", signed_in.account.?);
    try std.testing.expectEqual(@as(usize, 2), signed_in.limits.len);
    try std.testing.expectEqual(@as(u32, 300), signed_in.limits[0].window_minutes);
    try std.testing.expectEqual(@as(?f64, 40), signed_in.limits[0].used_percent);
    try std.testing.expectEqual(@as(?i64, 1_762_750_800_000), signed_in.limits[0].resets_at_ms);
    try std.testing.expectEqualStrings("Opus", signed_in.limits[1].scope.?);
    var signed_out: Gateway = .{ .arena = arena, .listing = opus_and_sonnet };
    const out = try (try modelsOver(arena, &signed_out)).status(arena, "claude");
    try std.testing.expect(!out.connected);
    try std.testing.expectEqualStrings("Claude Code is not signed in on this computer: run `claude` and sign in.", out.problem.?);
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

test "a request names its conversation to the gateway, and an ended conversation is let go there" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const fixture = try fixtures.load(arena, "anthropic", "text");
    const exchanges = try arena.dupe(foundation.replay.Exchange, fixture.exchanges);
    for (exchanges) |*exchange| exchange.request.url = claude.base_url ++ "/messages";
    var replay: foundation.replay.Replay = .init(arena, exchanges);
    var gateway: Gateway = .{ .arena = arena, .listing = opus_and_sonnet, .rest = replay.http(), .deletes = true };
    const models = try modelsOver(arena, &gateway);
    try models.refresh();
    var request = fixture.request;
    request.model = "claude/claude-opus-5-5";
    request.prompt_cache_key = "01a1c112-3830-78f7-9a37-442a361894eb";
    _ = try models.create(arena, request);
    try std.testing.expectEqualStrings("01a1c112-3830-78f7-9a37-442a361894eb", gateway.conversation.?);
    try models.forgetConversation(arena, "01a1c112-3830-78f7-9a37-442a361894eb");
    try std.testing.expectEqualStrings("DELETE " ++ claude.base_url ++ "/conversations/01a1c112-3830-78f7-9a37-442a361894eb", gateway.asked.items[gateway.asked.items.len - 1]);
}

test "the program that signs Claude Code in is the gateway's to tell" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var gateway: Gateway = .{ .arena = arena, .listing = opus_and_sonnet };
    const models = try modelsOver(arena, &gateway);
    const program = (try models.login(arena, "claude")).program;
    try std.testing.expectEqual(@as(usize, 3), program.argv.len);
    try std.testing.expectEqualStrings("/usr/local/bin/claude", program.argv[0]);
    try std.testing.expectEqualStrings("login", program.argv[2]);
    try std.testing.expectEqualStrings("CLAUDE_CONFIG_DIR", program.environment[0].name);
    try std.testing.expectEqualStrings("gateway://claude/v1/login", gateway.asked.items[gateway.asked.items.len - 1]);
    // A provider the host does not have tells none.
    try std.testing.expect((try models.login(arena, "nowhere")) == .failed);
}

test "an account the person added is reached at its own address on the gateway, and let go of there as it is removed" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const settings = try claude.driver.instance.?(arena, "01a1c11e-f9f4-7a31-8479-6c80a9b3dc03", .{});
    try std.testing.expectEqualStrings("gateway://claude/accounts/01a1c11e-f9f4-7a31-8479-6c80a9b3dc03/v1", settings.base_url.?);
    var gateway: Gateway = .{ .arena = arena, .listing = opus_and_sonnet, .account = "{\"email\":\"work@example.com\"}", .deletes = true };
    const test_host = try arena.create(TestHost);
    test_host.* = .{};
    const providers = try arena.dupe(seam.Provider, &.{.{ .id = "01a1c11e-f9f4-7a31-8479-6c80a9b3dc03", .name = "Claude · Work", .driver = &claude.driver, .settings = settings }});
    const models = try Models.init(arena, .{ .providers = providers, .host = test_host.host(gateway.network()) });
    try models.refresh();
    try std.testing.expect((try models.status(arena, "01a1c11e-f9f4-7a31-8479-6c80a9b3dc03")).connected);
    try std.testing.expectEqualStrings("gateway://claude/accounts/01a1c11e-f9f4-7a31-8479-6c80a9b3dc03/v1/account", gateway.asked.items[gateway.asked.items.len - 1]);
    try std.testing.expectEqual(null, try models.forgetAccount(arena, &providers[0]));
    try std.testing.expectEqualStrings("DELETE gateway://claude/accounts/01a1c11e-f9f4-7a31-8479-6c80a9b3dc03", gateway.asked.items[gateway.asked.items.len - 1]);
    // A gateway that could not let it go fails as it answered.
    gateway.deletes = false;
    try std.testing.expect(try models.forgetAccount(arena, &providers[0]) != null);
}

test "a plan's limit used up fails as a quota, given again when the gateway says, over the window it names" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var gateway: Gateway = .{ .arena = arena, .listing = opus_and_sonnet, .used_up_till = "1762000000" };
    const models = try modelsOver(arena, &gateway);
    try models.refresh();
    const fixture = try fixtures.load(arena, "anthropic", "text");
    var request = fixture.request;
    request.model = "claude/claude-opus-5-5";
    const response = try models.create(arena, request);
    const failed = response.@"error".?.octoii;
    try std.testing.expectEqual(vocabulary.FailureKind.quota, failed.kind);
    try std.testing.expect(!failed.retryable);
    try std.testing.expectEqual(@as(?i64, 1_762_000_000_000), failed.reset_at_ms);
    try std.testing.expectEqual(@as(?u32, 300), failed.window_minutes);
}
