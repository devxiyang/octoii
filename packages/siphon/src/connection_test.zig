//! A client's connection on a fake host, reached as the host reaches it — its messages delivered to Siphon's loop, what
//! it is sent taken from its outbox: greeted as the session its host's transport authenticated, its methods answered
//! once by their ids where its session's scopes open them, the host's access read and changed, and a thread it
//! follows sent as it goes — what streams of the model, its entries as they are appended, its state as it changes.
const std = @import("std");
const Allocator = std.mem.Allocator;
const vocabulary = @import("vocabulary");
const ai = @import("ai");
const Siphon = @import("Siphon.zig");
const Connection = @import("protocol.zig").Connection;
const Access = @import("protocol.zig").Access;
const threads = @import("threads.zig");
const image = @import("image.zig");
const testing = @import("testing.zig");
const log_test = @import("log_test.zig");
const runtime_ = @import("runtime.zig");
const Phase = runtime_.Phase;
const Changes = runtime_.Changes;

/// A client as the host carries it: its messages delivered, what it is sent taken.
const Client = struct {
    siphon: *Siphon,
    connection: *Connection,
    arena: Allocator,

    fn open(siphon: *Siphon, arena: Allocator) !Client {
        return openAs(siphon, arena, .{ .session = "s1", .scopes = Access.all_scopes });
    }

    /// A client the host's transport authenticated as `principal`, or as none.
    fn openAs(siphon: *Siphon, arena: Allocator, principal: ?Access.Principal) !Client {
        const connection = try siphon.clients.open(principal);
        return .{ .siphon = siphon, .connection = connection, .arena = arena };
    }

    /// Hangs the client up, the loop takes it, and the host lets go: the connection is freed.
    fn close(client: Client) !void {
        client.connection.hangUp();
        _ = try client.siphon.runtime.pump();
        client.connection.release();
    }

    fn send(client: Client, message: []const u8) void {
        client.connection.deliver(message) catch unreachable;
    }

    fn sendf(client: Client, comptime text: []const u8, arguments: anytype) !void {
        client.send(try client.arena.print(text, arguments));
    }

    /// What the client was sent since it last looked, read as JSON.
    fn taken(client: Client) ![]const std.json.Value {
        var out: std.ArrayList(std.json.Value) = .empty;
        var batch: [64][]u8 = undefined;
        while (true) {
            const count = client.connection.take(&batch, 0) catch break;
            if (count == 0) break;
            for (batch[0..count]) |message| {
                defer std.testing.allocator.free(message);
                try out.append(client.arena, try std.json.parseFromSliceLeaky(std.json.Value, client.arena, message, .{ .allocate = .alloc_always }));
            }
        }
        return out.items;
    }
};

fn field(value: std.json.Value, path: []const []const u8) ?std.json.Value {
    var at = value;
    for (path) |name| at = (if (at == .object) at.object.get(name) else null) orelse return null;
    return at;
}

const model = testing.model;

/// The bytes of the image a page of a file gives, and their size as they decode.
fn imageOf(arena: Allocator, page: std.json.Value) !struct { bytes: []const u8, size: image.Size } {
    const data = field(page, &.{"data"}).?.string;
    const bytes = try arena.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(data));
    try std.base64.standard.Decoder.decode(bytes, data);
    const decoded = try image.fitted(arena, bytes, .{ .width_max = 1 << 16, .height_max = 1 << 16, .pixels_max = 1 << 32, .bytes_max = 1 << 30 });
    return .{ .bytes = bytes, .size = decoded.original };
}

/// A reply streamed in two pieces of text.
fn streamed(arena: Allocator) !ai.testing.fake.Answer {
    const parts = try arena.dupe(vocabulary.OutputContent, &.{.{ .output_text = .{ .text = "Hello there" } }});
    const message: vocabulary.OutputItem = .{ .output_message = .{ .id = "m1", .content = .{ .parts = parts } } };
    const begun: vocabulary.OutputItem = .{ .output_message = .{ .id = "m1", .content = .{ .parts = &.{} } } };
    return .{ .events = try arena.dupe(vocabulary.ResponseStreamEvent, &.{
        .{ .created = .{ .response = .{ .id = "r", .status = .in_progress, .output = &.{} }, .sequence_number = 0 } },
        .{ .output_item_added = .{ .item = begun, .output_index = 0, .sequence_number = 1 } },
        .{ .output_text_delta = .{ .item_id = "m1", .output_index = 0, .content_index = 0, .delta = "Hello", .logprobs = &.{}, .sequence_number = 2 } },
        .{ .output_text_delta = .{ .item_id = "m1", .output_index = 0, .content_index = 0, .delta = " there", .logprobs = &.{}, .sequence_number = 3 } },
        .{ .output_item_done = .{ .item = message, .output_index = 0, .sequence_number = 4 } },
        .{ .completed = .{ .response = .{ .id = "r", .status = .completed, .output = try arena.dupe(vocabulary.OutputItem, &.{message}) }, .sequence_number = 5 } },
    }) };
}

test "a thread made naming no folder works in the default one, made for it, and belongs to no project" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const machine = try testing.openLocalMachine();
    defer _ = @import("beak.zig").h.beak_close(machine);
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try Siphon.open(std.testing.allocator, .{ .io = std.testing.io, .clock = clock.clock(), .machine = machine, .home = root }, .{});
    defer siphon.close();
    const client: Client = try .open(siphon, arena);
    client.send("{\"id\":\"1\",\"method\":\"hello\",\"params\":{\"protocol\":1}}");
    client.send("{\"id\":\"2\",\"method\":\"threads.create\",\"params\":{\"operation\":\"create-1\"}}");
    _ = try siphon.runtime.pump();
    const answers = try client.taken();
    const tid = field(answers[1], &.{ "result", "thread" }).?.string;
    const manifest = try threads.manifestOf(siphon.runtime.volume, &arena, try threads.pathOf(arena, tid));
    try std.testing.expectEqualStrings(try std.fs.path.join(arena, &.{ root, "octoii" }), manifest.workspace.?);
    try std.testing.expectEqual(@as(?[]const u8, null), manifest.project);
    try tmp.dir.access(std.testing.io, "octoii", .{});
    try client.close();
}

test "a client is greeted as its session, its methods answered by their ids, and a thread it follows sent as it goes" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var fake: ai.testing.Fake = .init(arena, &.{try streamed(arena)});
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try Siphon.open(std.testing.allocator, .{ .io = std.testing.io, .clock = clock.clock() }, .{ .providers = &providers });
    defer siphon.close();
    const client: Client = try .open(siphon, arena);

    client.send("{\"id\":\"1\",\"method\":\"threads.list\"}");
    client.send("{\"id\":\"2\",\"method\":\"hello\",\"params\":{\"protocol\":2}}");
    client.send("{\"id\":\"3\",\"method\":\"hello\",\"params\":{\"protocol\":1}}");
    client.send("{\"id\":\"4\",\"method\":\"threads.create\",\"params\":{\"manifest\":{\"model\":\"fake/m\",\"title\":\"Hello\"},\"operation\":\"create-1\"}}");
    _ = try siphon.runtime.pump();
    const answers = try client.taken();
    try std.testing.expectEqual(@as(usize, 4), answers.len);
    try std.testing.expectEqualStrings("not-admitted", field(answers[0], &.{ "error", "code" }).?.string);
    try std.testing.expectEqualStrings("protocol", field(answers[1], &.{ "error", "code" }).?.string);
    try std.testing.expectEqual(@as(i64, 1), field(answers[2], &.{ "result", "protocol" }).?.integer);
    try std.testing.expectEqualStrings("s1", field(answers[2], &.{ "result", "session" }).?.string);
    try std.testing.expectEqual(Access.all_scopes.len, field(answers[2], &.{ "result", "scopes" }).?.array.items.len);
    const tid = field(answers[3], &.{ "result", "thread" }).?.string;

    // A message is answered by its id wherever the id reads, as JSON-RPC answers one: one that holds more than its id,
    // its method and its params, and one whose params are not its method's, each refused as invalid.
    client.send("not json");
    client.send("{\"id\":\"4b\",\"method\":\"threads.deliver\",\"thread\":\"t\"}");
    client.send("{\"id\":\"4c\",\"method\":\"threads.deliver\",\"params\":{\"thread\":7}}");
    client.send("{\"id\":\"4d\",\"method\":\"threads.state\",\"params\":{\"thread\":\"t\",\"from\":null}}");
    _ = try siphon.runtime.pump();
    const refused = try client.taken();
    try std.testing.expectEqual(@as(usize, 4), refused.len);
    try std.testing.expect(field(refused[0], &.{"id"}).? == .null);
    try std.testing.expectEqualStrings("bad-message", field(refused[0], &.{ "error", "code" }).?.string);
    for (refused[1..], [_][]const u8{ "4b", "4c", "4d" }) |each, id| {
        try std.testing.expectEqualStrings(id, field(each, &.{"id"}).?.string);
        try std.testing.expectEqualStrings("invalid", field(each, &.{ "error", "code" }).?.string);
    }
    // A field meant for another method is told as one the method does not take.
    try std.testing.expectEqualStrings("The params hold a field the method does not take.", field(refused[3], &.{ "error", "message" }).?.string);

    try client.sendf("{{\"id\":\"5\",\"method\":\"threads.follow\",\"params\":{{\"thread\":\"{s}\"}}}}", .{tid});
    try client.sendf("{{\"id\":\"6\",\"method\":\"threads.deliver\",\"params\":{{\"thread\":\"{s}\",\"input\":{{\"message\":{{\"role\":\"user\",\"content\":\"hi\"}}}},\"operation\":\"op-1\"}}}}", .{tid});
    client.send("{\"id\":\"7\",\"method\":\"threads.list\"}");

    // The thread at rest, what was sent of it holds the model's stream, every entry once, in order, and its states.
    var kinds: std.ArrayList([]const u8) = .empty;
    var deltas: std.ArrayList(u8) = .empty;
    var last_state: ?std.json.Value = null;
    var listed = false;
    // What streamed, and the reply that came of it, name the one request they are of.
    var streamed_for: ?[]const u8 = null;
    var replied_for: ?[]const u8 = null;
    for (0..200) |_| {
        _ = try siphon.runtime.pump();
        for (try client.taken()) |message| {
            if (field(message, &.{ "result", "threads" })) |found| {
                try std.testing.expectEqualStrings("Hello", found.array.items[0].object.get("manifest").?.object.get("title").?.string);
                listed = true;
            }
            const event = (field(message, &.{"event"}) orelse continue).string;
            if (std.mem.eql(u8, event, "entries")) {
                for (field(message, &.{"entries"}).?.array.items) |entry| {
                    const kind = entry.object.get("type").?.string;
                    try kinds.append(arena, kind);
                    if (std.mem.eql(u8, kind, "reply")) replied_for = entry.object.get("request").?.string;
                }
            } else if (std.mem.eql(u8, event, "stream")) {
                const request = field(message, &.{"request"}).?.string;
                if (streamed_for) |before| try std.testing.expectEqualStrings(before, request);
                streamed_for = request;
                const data = field(message, &.{"data"}).?;
                if (std.mem.eql(u8, data.object.get("type").?.string, "response.output_text.delta")) {
                    try deltas.appendSlice(arena, data.object.get("delta").?.string);
                    try kinds.append(arena, "delta");
                }
            } else last_state = field(message, &.{"state"});
        }
        const now = try threads.state(siphon.runtime, arena, tid);
        if (now.status == .replied and kinds.items.len >= 6) break;
        siphon.runtime.waitForNews(20);
    }
    try std.testing.expect(listed);
    try std.testing.expectEqualStrings("Hello there", deltas.items);
    const expected = [_][]const u8{ "system", "input", "delta", "delta", "reply", "turn-end" };
    try std.testing.expectEqual(expected.len, kinds.items.len);
    for (expected, kinds.items) |want, got| try std.testing.expectEqualStrings(want, got);
    try std.testing.expectEqualStrings("replied", last_state.?.object.get("status").?.string);
    try std.testing.expectEqualStrings(streamed_for.?, replied_for.?);
    // At rest, the thread's main fiber alone, waiting on no request.
    const fibers = last_state.?.object.get("processes").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), fibers.len);
    try std.testing.expectEqualStrings("main", fibers[0].object.get("key").?.string);
    try std.testing.expectEqual(@as(usize, 0), fibers[0].object.get("requests").?.array.items.len);
    try client.close();
}

/// The host's access, as a test keeps it: one session, one link, and what was made and revoked.
const FakeAccess = struct {
    arena: Allocator,
    sessions: std.ArrayList(Access.Session) = .empty,
    links: std.ArrayList(Access.Link) = .empty,
    paired: ?[]const Access.Scope = null,

    fn access(fake: *FakeAccess) Access {
        return .{ .context = fake, .vtable = &.{ .list = list, .pair = pair, .revoke = revoke } };
    }

    fn list(context: *anyopaque, _: Allocator) anyerror!Access.Listed {
        const fake: *FakeAccess = @ptrCast(@alignCast(context));
        return .{ .sessions = fake.sessions.items, .links = fake.links.items };
    }

    fn pair(context: *anyopaque, _: Allocator, label: ?[]const u8, scopes: []const Access.Scope) anyerror!Access.Paired {
        const fake: *FakeAccess = @ptrCast(@alignCast(context));
        fake.paired = try fake.arena.dupe(Access.Scope, scopes);
        try fake.links.append(fake.arena, .{ .id = "l2", .scopes = fake.paired.?, .label = label, .created_at = 1_000, .expires_at = 301_000 });
        return .{ .id = "l2", .credential = "l2.secret", .expires_at = 301_000 };
    }

    fn revoke(context: *anyopaque, _: Allocator, id: []const u8) anyerror!Access.Revoked {
        const fake: *FakeAccess = @ptrCast(@alignCast(context));
        for (fake.sessions.items, 0..) |session, index| if (std.mem.eql(u8, session.id, id)) {
            _ = fake.sessions.orderedRemove(index);
            return .session;
        };
        return .none;
    }
};

test "a client holding no session is not greeted, and one is asked for what its session's scopes open alone" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try Siphon.open(std.testing.allocator, .{ .io = std.testing.io, .clock = clock.clock() }, .{});
    defer siphon.close();
    const stranger: Client = try .openAs(siphon, arena, null);
    const reader: Client = try .openAs(siphon, arena, .{ .session = "r1", .scopes = &.{.@"threads.read"} });
    stranger.send("{\"id\":\"1\",\"method\":\"hello\",\"params\":{\"protocol\":1}}");
    stranger.send("{\"id\":\"2\",\"method\":\"threads.list\"}");
    reader.send("{\"id\":\"1\",\"method\":\"hello\",\"params\":{\"protocol\":1}}");
    reader.send("{\"id\":\"2\",\"method\":\"threads.list\"}");
    reader.send("{\"id\":\"3\",\"method\":\"threads.create\",\"params\":{\"operation\":\"c1\"}}");
    _ = try siphon.runtime.pump();
    const refused = try stranger.taken();
    try std.testing.expectEqualStrings("not-admitted", field(refused[0], &.{ "error", "code" }).?.string);
    try std.testing.expectEqualStrings("not-admitted", field(refused[1], &.{ "error", "code" }).?.string);
    const read = try reader.taken();
    try std.testing.expect(field(read[1], &.{ "result", "threads" }) != null);
    try std.testing.expectEqualStrings("forbidden", field(read[2], &.{ "error", "code" }).?.string);
    try stranger.close();
    try reader.close();
}

test "a client reads the host's access, makes a link no wider than its session, and revokes a session, whose clients are let go" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var fake: FakeAccess = .{ .arena = arena };
    try fake.sessions.append(arena, .{ .id = "s1", .method = .cookie, .scopes = Access.all_scopes, .issued_at = 1_000, .expires_at = 2_000 });
    try fake.sessions.append(arena, .{ .id = "s2", .method = .bearer, .scopes = Access.all_scopes, .label = "phone", .issued_at = 1_000, .expires_at = 2_000 });
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try Siphon.open(std.testing.allocator, .{ .io = std.testing.io, .clock = clock.clock(), .access = fake.access() }, .{});
    defer siphon.close();
    const narrow: Access.Scope = .@"threads.read";
    const client: Client = try .openAs(siphon, arena, .{ .session = "s1", .scopes = &.{ narrow, .@"access.read", .@"access.write" } });
    const phone: Client = try .openAs(siphon, arena, .{ .session = "s2", .scopes = Access.all_scopes });
    client.send("{\"id\":\"1\",\"method\":\"hello\",\"params\":{\"protocol\":1}}");
    phone.send("{\"id\":\"1\",\"method\":\"hello\",\"params\":{\"protocol\":1}}");
    client.send("{\"id\":\"2\",\"method\":\"access.list\"}");
    client.send("{\"id\":\"3\",\"method\":\"access.pair\",\"params\":{\"scopes\":[\"threads.operate\"]}}");
    client.send("{\"id\":\"4\",\"method\":\"access.pair\",\"params\":{\"label\":\"laptop\"}}");
    client.send("{\"id\":\"5\",\"method\":\"access.revoke\",\"params\":{\"id\":\"s2\"}}");
    client.send("{\"id\":\"6\",\"method\":\"access.revoke\",\"params\":{\"id\":\"nobody\"}}");
    _ = try siphon.runtime.pump();
    const answers = try client.taken();
    const sessions = field(answers[1], &.{ "result", "sessions" }).?.array.items;
    try std.testing.expect(sessions[0].object.get("current").?.bool and sessions[0].object.get("connected").?.bool);
    try std.testing.expect(!sessions[1].object.get("current").?.bool and sessions[1].object.get("connected").?.bool);
    try std.testing.expectEqualStrings("forbidden", field(answers[2], &.{ "error", "code" }).?.string);
    try std.testing.expectEqualStrings("l2.secret", field(answers[3], &.{ "result", "credential" }).?.string);
    try std.testing.expectEqual(@as(usize, 3), fake.paired.?.len);
    try std.testing.expectEqualStrings("session", field(answers[4], &.{ "result", "revoked" }).?.string);
    try std.testing.expectEqualStrings("no-such-access", field(answers[5], &.{ "error", "code" }).?.string);
    // The phone's session revoked, its connection is let go: its outbox closed, once what was in it is taken.
    _ = try phone.taken();
    var batch: [1][]u8 = undefined;
    try std.testing.expectError(error.Closed, phone.connection.take(&batch, 0));
    try client.close();
    try phone.close();
}

test "a client sets a provider's key and removes it, told how each provider is connected and what kind of credential it holds, never the key" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var fake: ai.testing.Fake = .init(arena, &.{});
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(model)} }};
    var held: testing.Credentials = .{ .arena = arena };
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try Siphon.open(std.testing.allocator, .{ .io = std.testing.io, .clock = clock.clock(), .credentials = held.credentials() }, .{ .providers = &providers });
    defer siphon.close();
    const client: Client = try .open(siphon, arena);
    client.send("{\"id\":\"1\",\"method\":\"hello\",\"params\":{\"protocol\":1}}");
    client.send("{\"id\":\"2\",\"method\":\"providers.list\"}");
    client.send("{\"id\":\"3\",\"method\":\"credentials.set\",\"params\":{\"provider\":\"fake\",\"api_key\":\"sk-kept\"}}");
    client.send("{\"id\":\"4\",\"method\":\"providers.list\"}");
    client.send("{\"id\":\"5\",\"method\":\"credentials.set\",\"params\":{\"provider\":\"nobody\",\"api_key\":\"x\"}}");
    _ = try siphon.runtime.pump();
    const answers = try client.taken();
    try std.testing.expectEqual(@as(usize, 5), answers.len);
    try std.testing.expect(field(answers[1], &.{ "result", "providers" }).?.array.items[0].object.get("credential") == null);
    try std.testing.expectEqualStrings("sk-kept", held.kept.get("fake").?.api_key);
    const listed = field(answers[3], &.{ "result", "providers" }).?.array.items[0];
    try std.testing.expectEqualStrings("fake", listed.object.get("id").?.string);
    try std.testing.expectEqualStrings("Fake", listed.object.get("name").?.string);
    try std.testing.expectEqualStrings("api_key", listed.object.get("connects").?.string);
    try std.testing.expectEqualStrings("api_key", listed.object.get("credential").?.string);
    try std.testing.expectEqualStrings("unknown-provider", field(answers[4], &.{ "error", "code" }).?.string);
    // What a client is told holds no key.
    for (answers) |answer| try std.testing.expect(std.mem.indexOf(u8, try std.json.Stringify.valueAlloc(arena, answer, .{}), "sk-kept") == null);

    client.send("{\"id\":\"6\",\"method\":\"credentials.remove\",\"params\":{\"provider\":\"fake\"}}");
    client.send("{\"id\":\"7\",\"method\":\"providers.list\"}");
    _ = try siphon.runtime.pump();
    const after = try client.taken();
    try std.testing.expect(held.kept.get("fake") == null);
    try std.testing.expect(field(after[1], &.{ "result", "providers" }).?.array.items[0].object.get("credential") == null);
    try client.close();
}

/// The providers a client was told of last, each as listed: its id, its name, and the provider it is another account of.
fn providersOf(client: Client) ![]const [3][]const u8 {
    var out: std.ArrayList([3][]const u8) = .empty;
    for (try client.taken()) |message| {
        const listed = field(message, &.{ "result", "providers" }) orelse continue;
        out.clearRetainingCapacity();
        for (listed.array.items) |each| {
            const of = if (each.object.get("account")) |account| account.object.get("of").?.string else "";
            try out.append(client.arena, .{ each.object.get("id").?.string, each.object.get("name").?.string, of });
        }
    }
    return out.items;
}

test "a client adds an account of the host's provider, which the models reach by its id, and renames and removes it" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var fake: ai.testing.Fake = .init(arena, &.{});
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(model)} }};
    var held: testing.Credentials = .{ .arena = arena };
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try Siphon.open(std.testing.allocator, .{ .io = std.testing.io, .clock = clock.clock(), .credentials = held.credentials() }, .{ .providers = &providers });
    defer siphon.close();
    const client: Client = try .open(siphon, arena);
    client.send("{\"id\":\"1\",\"method\":\"hello\",\"params\":{\"protocol\":1}}");
    client.send("{\"id\":\"2\",\"method\":\"accounts.add\",\"params\":{\"provider\":\"fake\",\"name\":\" Work \",\"operation\":\"add-1\"}}");
    client.send("{\"id\":\"3\",\"method\":\"accounts.add\",\"params\":{\"provider\":\"fake\",\"name\":\"Work\",\"operation\":\"add-1\"}}");
    client.send("{\"id\":\"4\",\"method\":\"accounts.add\",\"params\":{\"provider\":\"nobody\",\"name\":\"Work\",\"operation\":\"add-2\"}}");
    client.send("{\"id\":\"5\",\"method\":\"accounts.add\",\"params\":{\"provider\":\"fake\",\"name\":\"  \",\"operation\":\"add-3\"}}");
    _ = try siphon.runtime.pump();
    const answers = try client.taken();
    const added = field(answers[1], &.{ "result", "account" }).?.string;
    try std.testing.expectEqualStrings(added, field(answers[2], &.{ "result", "account" }).?.string);
    try std.testing.expectEqualStrings("unknown-provider", field(answers[3], &.{ "error", "code" }).?.string);
    try std.testing.expectEqualStrings("invalid", field(answers[4], &.{ "error", "code" }).?.string);
    try std.testing.expect(siphon.models.provider(added) != null);

    client.send("{\"id\":\"6\",\"method\":\"providers.list\"}");
    _ = try siphon.runtime.pump();
    const listed = try providersOf(client);
    try std.testing.expectEqual(@as(usize, 2), listed.len);
    try std.testing.expectEqualStrings(added, listed[1][0]);
    try std.testing.expectEqualStrings("Fake · Work", listed[1][1]);
    try std.testing.expectEqualStrings("fake", listed[1][2]);

    try client.sendf("{{\"id\":\"7\",\"method\":\"accounts.rename\",\"params\":{{\"account\":\"{s}\",\"name\":\"Home\"}}}}", .{added});
    client.send("{\"id\":\"8\",\"method\":\"providers.list\"}");
    _ = try siphon.runtime.pump();
    try std.testing.expectEqualStrings("Fake · Home", (try providersOf(client))[1][1]);

    try client.sendf("{{\"id\":\"9\",\"method\":\"accounts.remove\",\"params\":{{\"account\":\"{s}\"}}}}", .{added});
    try client.sendf("{{\"id\":\"10\",\"method\":\"accounts.remove\",\"params\":{{\"account\":\"{s}\"}}}}", .{added});
    client.send("{\"id\":\"11\",\"method\":\"providers.list\"}");
    _ = try siphon.runtime.pump();
    const after = try client.taken();
    try std.testing.expectEqualStrings("no-such-account", field(after[1], &.{ "error", "code" }).?.string);
    try std.testing.expectEqual(@as(usize, 1), field(after[2], &.{ "result", "providers" }).?.array.items.len);
    try std.testing.expect(siphon.models.provider(added) == null);
    try client.close();
}

test "a client is told the models a thread may run with, each as the catalogue describes it" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var fake: ai.testing.Fake = .init(arena, &.{});
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try Siphon.open(std.testing.allocator, .{ .io = std.testing.io, .clock = clock.clock() }, .{ .providers = &providers });
    defer siphon.close();
    const client: Client = try .open(siphon, arena);
    client.send("{\"id\":\"1\",\"method\":\"hello\",\"params\":{\"protocol\":1}}");
    client.send("{\"id\":\"2\",\"method\":\"models.list\",\"params\":{}}");
    _ = try siphon.runtime.pump();
    const answers = try client.taken();
    const listed = field(answers[1], &.{ "result", "models" }).?.array.items;
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqualStrings(model.id, listed[0].object.get("id").?.string);
    try std.testing.expectEqualStrings("fake", field(listed[0], &.{ "octoii", "provider" }).?.string);
    try client.close();
}

test "a client reads a thread's latest entries, back a page at a time to its start, and follows on from where the log ended" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.open(&clock, .memory);
    defer siphon.close();
    const tid = try threads.create(siphon.runtime, arena, .{}, "create");
    const thread = try threads.pathOf(arena, tid);
    try log_test.writeSegments(siphon, arena, thread, &.{ try log_test.linesOf(arena, 0, 6, 100), try log_test.linesOf(arena, 6, 10, 100) });
    const client: Client = try .open(siphon, arena);
    client.send("{\"id\":\"1\",\"method\":\"hello\",\"params\":{\"protocol\":1}}");
    try client.sendf("{{\"id\":\"2\",\"method\":\"threads.read\",\"params\":{{\"thread\":\"{s}\",\"limit\":3}}}}", .{tid});
    try client.sendf("{{\"id\":\"3\",\"method\":\"threads.read\",\"params\":{{\"thread\":\"{s}\",\"before\":\"000007\",\"limit\":100}}}}", .{tid});
    _ = try siphon.runtime.pump();
    const answers = try client.taken();
    const latest = field(answers[1], &.{"result"}).?;
    const ids = latest.object.get("entries").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), ids.len);
    try std.testing.expectEqualStrings("000007", ids[0].object.get("id").?.string);
    try std.testing.expect(!latest.object.get("complete").?.bool);
    const older = field(answers[2], &.{"result"}).?;
    try std.testing.expectEqual(@as(usize, 7), older.object.get("entries").?.array.items.len);
    try std.testing.expect(older.object.get("complete").?.bool);

    // Followed from where the log ended as it was read: nothing it read is sent again, what is appended after is.
    const end = latest.object.get("end").?.object;
    try client.sendf("{{\"id\":\"4\",\"method\":\"threads.follow\",\"params\":{{\"thread\":\"{s}\",\"from\":{{\"segment\":\"{s}\",\"offset\":{d}}}}}}}", .{ tid, end.get("segment").?.string, end.get("offset").?.integer });
    _ = try siphon.runtime.pump();
    for (try client.taken()) |message| try std.testing.expect(field(message, &.{"entries"}) == null);
    try log_test.writeSegments(siphon, arena, thread, &.{try log_test.linesOf(arena, 10, 11, 100)});
    _ = try siphon.runtime.pump();
    var appended: usize = 0;
    for (try client.taken()) |message| if (field(message, &.{"entries"})) |entries| {
        appended += entries.array.items.len;
        try std.testing.expectEqualStrings("000010", entries.array.items[0].object.get("id").?.string);
    };
    try std.testing.expectEqual(@as(usize, 1), appended);
    try client.close();
}

/// The rows of the thread list a client was sent since it last looked: each thread's id, and its status.
fn rowsOf(client: Client) ![]const [2][]const u8 {
    var out: std.ArrayList([2][]const u8) = .empty;
    for (try client.taken()) |message| {
        const event = field(message, &.{"event"}) orelse continue;
        if (!std.mem.eql(u8, event.string, "thread")) continue;
        try out.append(client.arena, .{ field(message, &.{ "thread", "id" }).?.string, field(message, &.{ "thread", "standing", "status" }).?.string });
    }
    return out.items;
}

test "a thread deleted is gone for the clients that watch the list, and followed no more by those that followed it" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.open(&clock, .memory);
    defer siphon.close();
    const kept = try threads.create(siphon.runtime, arena, .{ .title = "kept" }, "create-1");
    const doomed = try threads.create(siphon.runtime, arena, .{ .title = "doomed" }, "create-2");
    const client: Client = try .open(siphon, arena);
    client.send("{\"id\":\"1\",\"method\":\"hello\",\"params\":{\"protocol\":1}}");
    client.send("{\"id\":\"2\",\"method\":\"threads.watch\"}");
    try client.sendf("{{\"id\":\"3\",\"method\":\"threads.follow\",\"params\":{{\"thread\":\"{s}\"}}}}", .{doomed});
    for (0..5) |_| _ = try siphon.runtime.pump();
    _ = try client.taken();
    try client.sendf("{{\"id\":\"4\",\"method\":\"threads.delete\",\"params\":{{\"thread\":\"{s}\"}}}}", .{doomed});
    for (0..5) |_| _ = try siphon.runtime.pump();
    var answered = false;
    var gone: ?[]const u8 = null;
    for (try client.taken()) |message| {
        if (field(message, &.{"id"})) |id| if (std.mem.eql(u8, id.string, "4")) {
            answered = field(message, &.{"result"}) != null;
        };
        if (field(message, &.{"event"})) |event| if (std.mem.eql(u8, event.string, "thread-gone")) {
            gone = field(message, &.{"thread"}).?.string;
        };
    }
    try std.testing.expect(answered);
    try std.testing.expectEqualStrings(doomed, gone.?);
    const rows = try threads.list(siphon.runtime, arena);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings(kept, rows[0].id);
    try client.close();
}

/// A provider that keeps conversations, as the agent gateway keeps Claude Code's sessions: each it was had let go of
/// kept, as its task tells it.
const Keeper = struct {
    lock: std.Io.Mutex = .init,
    arena_allocator: std.heap.ArenaAllocator,
    forgotten: std.ArrayList([]const u8) = .empty,

    fn forget(call: *ai.driver.Call, conversation: []const u8) ai.failure.Error!void {
        const keeper: *Keeper = @ptrCast(@alignCast(call.provider.driver.context.?));
        keeper.lock.lockUncancelable(std.testing.io);
        defer keeper.lock.unlock(std.testing.io);
        const arena = keeper.arena_allocator.allocator();
        try keeper.forgotten.append(arena, try arena.dupe(u8, conversation));
    }

    fn told(keeper: *Keeper) bool {
        keeper.lock.lockUncancelable(std.testing.io);
        defer keeper.lock.unlock(std.testing.io);
        return keeper.forgotten.items.len > 0;
    }
};

test "a thread deleted has the providers that keep conversations let go of its own, off the loop" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var keeper: Keeper = .{ .arena_allocator = .init(std.testing.allocator) };
    defer keeper.arena_allocator.deinit();
    const keeping: ai.driver.Driver = .{ .id = "keeper", .name = "Keeper", .context = &keeper, .forget = Keeper.forget };
    const providers = [_]ai.driver.Provider{.{ .id = "keeper", .name = "Keeper", .driver = &keeping }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.openOver(&clock, .memory, &providers);
    defer siphon.close();
    const doomed = try threads.create(siphon.runtime, arena, .{ .title = "doomed" }, "create-1");
    const client: Client = try .open(siphon, arena);
    client.send("{\"id\":\"1\",\"method\":\"hello\",\"params\":{\"protocol\":1}}");
    try client.sendf("{{\"id\":\"2\",\"method\":\"threads.delete\",\"params\":{{\"thread\":\"{s}\"}}}}", .{doomed});
    try testing.pumpUntil(siphon, &keeper, Keeper.told);
    try std.testing.expectEqualStrings(doomed, keeper.forgotten.items[0]);
    try client.close();
}

test "a client watching the list of threads is answered with it, then sent a row of a thread as it changes, and no other" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.open(&clock, .memory);
    defer siphon.close();
    const first = try threads.create(siphon.runtime, arena, .{ .title = "first" }, "create-1");
    const second = try threads.create(siphon.runtime, arena, .{ .title = "second" }, "create-2");
    const client: Client = try .open(siphon, arena);
    client.send("{\"id\":\"1\",\"method\":\"hello\",\"params\":{\"protocol\":1}}");
    client.send("{\"id\":\"2\",\"method\":\"threads.watch\"}");
    _ = try siphon.runtime.pump();
    // Answered with the list as it stands, every row in it; no row sent beside the answer.
    var listed: []const std.json.Value = &.{};
    var rows: usize = 0;
    for (try client.taken()) |message| {
        if (field(message, &.{ "result", "threads" })) |found| listed = found.array.items;
        if (field(message, &.{"event"})) |event| rows += @intFromBool(std.mem.eql(u8, event.string, "thread"));
    }
    try std.testing.expectEqual(@as(usize, 2), listed.len);
    try std.testing.expectEqualStrings(first, listed[0].object.get("id").?.string);
    try std.testing.expectEqualStrings(second, listed[1].object.get("id").?.string);
    try std.testing.expectEqual(@as(usize, 0), rows);

    // Settled, a thread made is sent alone, a row each time its row changes as its main fiber starts.
    for (0..5) |_| _ = try siphon.runtime.pump();
    _ = try rowsOf(client);
    const third = try threads.create(siphon.runtime, arena, .{ .title = "third" }, "create-3");
    for (0..5) |_| _ = try siphon.runtime.pump();
    const made = try rowsOf(client);
    try std.testing.expect(made.len >= 1);
    for (made) |row| try std.testing.expectEqualStrings(third, row[0]);

    // A commit that touches no thread sends no row.
    var elsewhere: Changes = .{ .arena = arena };
    try elsewhere.mkdir("t.elsewhere");
    _ = try siphon.runtime.commit(&elsewhere);
    _ = try siphon.runtime.pump();
    try std.testing.expectEqual(@as(usize, 0), (try rowsOf(client)).len);
    try client.close();
}

/// The offsets of the events of the stream of `key` a client was sent since it last looked, in the order they came.
fn offsetsOf(client: Client, key: []const u8) ![]const i64 {
    var out: std.ArrayList(i64) = .empty;
    for (try client.taken()) |message| {
        const event = field(message, &.{"event"}) orelse continue;
        if (!std.mem.eql(u8, event.string, "stream") or !std.mem.eql(u8, field(message, &.{"request"}).?.string, key)) continue;
        try out.append(client.arena, field(message, &.{"offset"}).?.integer);
    }
    return out.items;
}

test "a client that follows a thread mid-stream is sent what streamed so far, from its start, then what streams after" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.open(&clock, .memory);
    defer siphon.close();
    const tid = try threads.create(siphon.runtime, arena, .{}, "create");
    for (0..3) |_| try siphon.runtime.publish(tid, "r1", "{\"delta\":\"x\"}");
    _ = try siphon.runtime.pump();

    const late: Client = try .open(siphon, arena);
    late.send("{\"id\":\"1\",\"method\":\"hello\",\"params\":{\"protocol\":1}}");
    try late.sendf("{{\"id\":\"2\",\"method\":\"threads.follow\",\"params\":{{\"thread\":\"{s}\"}}}}", .{tid});
    _ = try siphon.runtime.pump();
    try std.testing.expectEqualSlices(i64, &.{ 0, 1, 2 }, try offsetsOf(late, "r1"));
    try siphon.runtime.publish(tid, "r1", "{\"delta\":\"y\"}");
    _ = try siphon.runtime.pump();
    try std.testing.expectEqualSlices(i64, &.{3}, try offsetsOf(late, "r1"));

    // Its request's task ended, the stream is let go: one who follows after is sent none of it.
    try siphon.runtime.endStream("r1");
    _ = try siphon.runtime.pump();
    const later: Client = try .open(siphon, arena);
    later.send("{\"id\":\"1\",\"method\":\"hello\",\"params\":{\"protocol\":1}}");
    try later.sendf("{{\"id\":\"2\",\"method\":\"threads.follow\",\"params\":{{\"thread\":\"{s}\"}}}}", .{tid});
    _ = try siphon.runtime.pump();
    try std.testing.expectEqual(@as(usize, 0), (try offsetsOf(later, "r1")).len);
    try late.close();
    try later.close();
}

/// A fiber that makes a request no handler acts on, as one a person answers, and ends once it is answered.
const Holding = struct {
    const kind = "test.holding";

    fn phase(_: ?*anyopaque, run: *Phase) anyerror!void {
        if (run.checkpoint.len == 0) {
            try run.request("held", "k1", null);
            return run.waitForMail("asked", "k1");
        }
        _ = try run.mailOf("k1") orelse return run.waitForMail("asked", "k1");
        try run.take("k1");
        return run.done(null);
    }
};

test "a thread followed is sent its state as its fibers change, though its log does not" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.open(&clock, .memory);
    defer siphon.close();
    try siphon.runtime.register(.{ .kind = Holding.kind, .phase = Holding.phase });
    const tid = try threads.create(siphon.runtime, arena, .{}, "create");
    const thread = try threads.pathOf(arena, tid);
    var started: Changes = .{ .arena = arena };
    try started.start(thread, "holding", Holding.kind, siphon.runtime.versionOf(Holding.kind).?, "", "");
    _ = try siphon.runtime.commit(&started);
    const client: Client = try .open(siphon, arena);
    client.send("{\"id\":\"1\",\"method\":\"hello\",\"params\":{\"protocol\":1}}");
    try client.sendf("{{\"id\":\"2\",\"method\":\"threads.follow\",\"params\":{{\"thread\":\"{s}\"}}}}", .{tid});

    // The fiber waits on its request, as the state sent says.
    var waiting = false;
    for (0..20) |_| {
        _ = try siphon.runtime.pump();
        for (try client.taken()) |message| if (stateOf(message, "holding")) |fiber| {
            waiting = fiber.object.get("requests").?.array.items.len == 1;
        };
        if (waiting) break;
    }
    try std.testing.expect(waiting);

    // Answered, the fiber ends: no entry is appended, and the client is sent the state all the same.
    const fiber = try @import("beak.zig").childPath(arena, thread, "holding");
    const record = (try siphon.runtime.volume.stat(&arena, fiber)).?.directory.*.process.*;
    var answered: Changes = .{ .arena = arena };
    try answered.answer(fiber, record.started, "k1", runtime_.Request.answered_name, "true");
    _ = try siphon.runtime.commit(&answered);
    var ended = false;
    for (0..20) |_| {
        _ = try siphon.runtime.pump();
        for (try client.taken()) |message| {
            try std.testing.expect(field(message, &.{"entries"}) == null);
            if (stateOf(message, "holding")) |each| ended = std.mem.eql(u8, each.object.get("state").?.string, "zombie");
        }
        if (ended) break;
    }
    try std.testing.expect(ended);
    try client.close();
}

/// The fiber of `key` in a state event `message`; null for any other message, or a state without it.
fn stateOf(message: std.json.Value, key: []const u8) ?std.json.Value {
    const event = field(message, &.{"event"}) orelse return null;
    if (!std.mem.eql(u8, event.string, "state")) return null;
    for (field(message, &.{ "state", "processes" }).?.array.items) |fiber| {
        if (std.mem.eql(u8, fiber.object.get("key").?.string, key)) return fiber;
    }
    return null;
}

test "a thread followed is fed a page at a time while its client's outbox has room, each entry once, in order" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.open(&clock, .memory);
    defer siphon.close();
    const client: Client = try .open(siphon, arena);
    client.send("{\"id\":\"1\",\"method\":\"hello\",\"params\":{\"protocol\":1}}");
    const tid = try threads.create(siphon.runtime, arena, .{}, "create");
    // A log of about 3 MB, in two segments.
    const thread = try threads.pathOf(arena, tid);
    try log_test.writeSegments(siphon, arena, thread, &.{ try log_test.linesOf(arena, 0, 2000, 1000), try log_test.linesOf(arena, 2000, 3000, 1000) });
    try client.sendf("{{\"id\":\"2\",\"method\":\"threads.follow\",\"params\":{{\"thread\":\"{s}\"}}}}", .{tid});

    // Not taken, what waits for the client stays near the room a feed waits for, far short of the log.
    for (0..20) |_| _ = try siphon.runtime.pump();
    try std.testing.expect(client.connection.queued.load(.seq_cst) < Connection.feed_room_bytes + 2 * @import("protocol.zig").Following.page_bytes);

    // Taken as it comes, the log is sent whole, each entry once and in order, and its state once after.
    var next: usize = 0;
    var states: usize = 0;
    for (0..200) |_| {
        for (try client.taken()) |message| {
            const event = (field(message, &.{"event"}) orelse continue).string;
            if (std.mem.eql(u8, event, "state")) {
                try std.testing.expectEqual(@as(usize, 3000), next);
                states += 1;
            } else if (std.mem.eql(u8, event, "entries")) for (field(message, &.{"entries"}).?.array.items) |entry| {
                try std.testing.expectEqualStrings(try arena.print("{d:0>6}", .{next}), entry.object.get("id").?.string);
                next += 1;
            };
        }
        if (states == 1) break;
        _ = try siphon.runtime.pump();
    }
    try std.testing.expectEqual(@as(usize, 3000), next);
    try std.testing.expectEqual(@as(usize, 1), states);
    try client.close();
}

test "a client is let go as Redis lets one go: at once past its outbox's hard bound, past its soft one after a while" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.open(&clock, .memory);
    defer siphon.close();
    const tid = try threads.create(siphon.runtime, arena, .{}, "create");
    const event = try arena.print("{{\"delta\":\"{s}\"}}", .{try arena.alloc(u8, 1 << 20)});
    @memset(event[10 .. event.len - 2], 'x');
    const slow: Client = try .open(siphon, arena);
    const stuck: Client = try .open(siphon, arena);
    for ([_]Client{ slow, stuck }) |client| {
        client.send("{\"id\":\"1\",\"method\":\"hello\",\"params\":{\"protocol\":1}}");
        try client.sendf("{{\"id\":\"2\",\"method\":\"threads.follow\",\"params\":{{\"thread\":\"{s}\"}}}}", .{tid});
    }
    _ = try siphon.runtime.pump();
    _ = try slow.taken();

    // Ten of a megabyte each, none taken: both past the soft bound, within the hard one.
    for (0..10) |_| try siphon.runtime.publish(tid, "k", event);
    _ = try siphon.runtime.pump();
    try std.testing.expect(!slow.connection.closed and !stuck.connection.closed);
    // The slow one takes what it was sent; the stuck one, past the soft bound for longer than it may be, is let go.
    _ = try slow.taken();
    clock.now_ms += Connection.outbox_soft_ms + 1;
    _ = try siphon.runtime.pump();
    try std.testing.expect(!slow.connection.closed and stuck.connection.closed);

    // Past the hard bound, a client is let go at once.
    for (0..33) |_| try siphon.runtime.publish(tid, "k", event);
    _ = try siphon.runtime.pump();
    try std.testing.expect(slow.connection.closed);
    try slow.close();
    try stuck.close();
}

/// The settings events a client was sent since it last looked.
fn settingsSent(client: Client) ![]const std.json.Value {
    var out: std.ArrayList(std.json.Value) = .empty;
    for (try client.taken()) |message| {
        const event = field(message, &.{"event"}) orelse continue;
        if (std.mem.eql(u8, event.string, "settings")) try out.append(client.arena, message);
    }
    return out.items;
}

test "a client watches the settings — the environment's and its device's — sets them as its scopes allow, and threads are made in the mode they name" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var fake: FakeAccess = .{ .arena = arena };
    try fake.sessions.append(arena, .{ .id = "s1", .method = .cookie, .scopes = Access.all_scopes, .issued_at = 1_000, .expires_at = 2_000 });
    try fake.sessions.append(arena, .{ .id = "s2", .method = .cookie, .scopes = &.{.@"threads.read"}, .issued_at = 1_000, .expires_at = 2_000 });
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try Siphon.open(std.testing.allocator, .{ .io = std.testing.io, .clock = clock.clock(), .access = fake.access() }, .{});
    defer siphon.close();
    const laptop: Client = try .openAs(siphon, arena, .{ .session = "s1", .scopes = Access.all_scopes });
    const viewer: Client = try .openAs(siphon, arena, .{ .session = "s2", .scopes = &.{.@"threads.read"} });
    for ([_]Client{ laptop, viewer }) |client| {
        client.send("{\"id\":\"1\",\"method\":\"hello\",\"params\":{\"protocol\":1}}");
        client.send("{\"id\":\"2\",\"method\":\"settings.watch\"}");
    }
    _ = try siphon.runtime.pump();
    // Answered with the settings as they stand: the defaults, and a device that set nothing.
    const watched = (try laptop.taken())[1];
    try std.testing.expectEqualStrings("default", field(watched, &.{ "result", "environment", "thread_mode" }).?.string);
    try std.testing.expectEqual(@as(usize, 0), field(watched, &.{ "result", "device" }).?.object.count());
    _ = try viewer.taken();

    // A device's settings are its own: set by its client, sent to it alone; the environment's are every client's.
    laptop.send("{\"id\":\"3\",\"method\":\"settings.set\",\"params\":{\"device\":{\"theme\":\"dark\"}}}");
    viewer.send("{\"id\":\"3\",\"method\":\"settings.set\",\"params\":{\"environment\":{\"thread_mode\":\"full-access\"}}}");
    viewer.send("{\"id\":\"4\",\"method\":\"settings.set\",\"params\":{\"device\":[1]}}");
    for (0..3) |_| _ = try siphon.runtime.pump();
    const laptop_told = try settingsSent(laptop);
    try std.testing.expectEqual(@as(usize, 1), laptop_told.len);
    try std.testing.expectEqualStrings("dark", field(laptop_told[0], &.{ "device", "theme" }).?.string);
    var viewer_codes: std.ArrayList([]const u8) = .empty;
    var viewer_settings: usize = 0;
    for (try viewer.taken()) |message| {
        if (field(message, &.{ "error", "code" })) |code| try viewer_codes.append(arena, code.string);
        if (field(message, &.{"event"}) != null) viewer_settings += 1;
    }
    try std.testing.expectEqualSlices(u8, "forbidden", viewer_codes.items[0]);
    try std.testing.expectEqualSlices(u8, "invalid", viewer_codes.items[1]);
    try std.testing.expectEqual(@as(usize, 0), viewer_settings);

    laptop.send("{\"id\":\"4\",\"method\":\"settings.set\",\"params\":{\"environment\":{\"thread_mode\":\"auto\",\"favorite_models\":[\"fake/m\"]}}}");
    for (0..3) |_| _ = try siphon.runtime.pump();
    for ([_]Client{ laptop, viewer }) |client| {
        const told = try settingsSent(client);
        try std.testing.expectEqual(@as(usize, 1), told.len);
        try std.testing.expectEqualStrings("auto", field(told[0], &.{ "environment", "thread_mode" }).?.string);
    }

    // A thread made with no mode starts in the one the environment names; one given its own keeps it.
    laptop.send("{\"id\":\"5\",\"method\":\"threads.create\",\"params\":{\"operation\":\"c1\"}}");
    laptop.send("{\"id\":\"6\",\"method\":\"threads.create\",\"params\":{\"manifest\":{\"mode\":\"full-access\"},\"operation\":\"c2\"}}");
    _ = try siphon.runtime.pump();
    var made: std.ArrayList([]const u8) = .empty;
    for (try laptop.taken()) |message| if (field(message, &.{ "result", "thread" })) |tid| try made.append(arena, tid.string);
    const modes = [_]threads.Mode{ .auto, .@"full-access" };
    for (made.items, modes) |tid, mode| {
        try std.testing.expectEqual(mode, (try threads.manifestOf(siphon.runtime.volume, &arena, try threads.pathOf(arena, tid))).mode);
    }

    // A session revoked takes its device's settings with it.
    laptop.send("{\"id\":\"7\",\"method\":\"access.revoke\",\"params\":{\"id\":\"s1\"}}");
    _ = try siphon.runtime.pump();
    try std.testing.expect(try siphon.runtime.volume.stat(&arena, "siphon.settings/devices/s1.json") == null);
    try laptop.close();
    try viewer.close();
}

/// A provider signed in to in a browser, as a test has it: its sign-in sends the browser to the issuer with the host's
/// address to come back to, and ends where the address it came back with holds a good code.
const SigningIn = struct {
    var driver: ai.driver.Driver = .{ .id = "signing", .name = "Signing", .sign_in = begin };

    fn begin(call: *ai.driver.Call, options: ai.driver.SignInOptions) ai.failure.Error!ai.driver.SignIn {
        const url = call.arena.print("https://issuer.example/authorize?redirect_uri={s}", .{options.redirect_uri}) catch return error.OutOfMemory;
        return .{ .url = url, .attempt = call, .finish = finish };
    }

    fn finish(call: *ai.driver.Call, _: *anyopaque, redirect: []const u8) ai.failure.Error!void {
        if (std.mem.indexOf(u8, redirect, "code=good") == null) return call.failWith(.auth, "The code is not good", .{});
    }
};

/// What a client was answered for the message `id`, pumped for as its job runs; the other messages it was sent kept.
fn answerOf(siphon: *Siphon, client: Client, id: []const u8) !std.json.Value {
    const Waiting = struct {
        client: Client,
        id: []const u8,
        found: ?std.json.Value = null,

        fn answered(waiting: *@This()) bool {
            for (waiting.client.taken() catch return false) |message| {
                const told = field(message, &.{"id"}) orelse continue;
                if (told == .string and std.mem.eql(u8, told.string, waiting.id)) waiting.found = message;
            }
            return waiting.found != null;
        }
    };
    var waiting: Waiting = .{ .client = client, .id = id };
    try testing.pumpUntil(siphon, &waiting, Waiting.answered);
    return waiting.found.?;
}

test "a client asks how a provider stands, lists the models again, and signs in to one in a browser, off the loop" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var fake: ai.testing.Fake = .init(arena, &.{});
    const providers = [_]ai.driver.Provider{
        .{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(model)} },
        .{ .id = "signing", .name = "Signing", .driver = &SigningIn.driver },
    };
    var held: testing.Credentials = .{ .arena = arena };
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try Siphon.open(std.testing.allocator, .{
        .io = std.testing.io,
        .clock = clock.clock(),
        .credentials = held.credentials(),
        .sign_in_redirect = "http://127.0.0.1:7600/auth/callback",
    }, .{ .providers = &providers });
    defer siphon.close();
    const client: Client = try .open(siphon, arena);
    client.send("{\"id\":\"1\",\"method\":\"hello\",\"params\":{\"protocol\":1}}");
    _ = try answerOf(siphon, client, "1");

    // A provider with no key kept is not connected, and says why; the models listed again answer once done.
    client.send("{\"id\":\"2\",\"method\":\"providers.status\",\"params\":{\"provider\":\"fake\"}}");
    const unconnected = try answerOf(siphon, client, "2");
    try std.testing.expect(!field(unconnected, &.{ "result", "connected" }).?.bool);
    client.send("{\"id\":\"3\",\"method\":\"models.refresh\"}");
    try std.testing.expect(field(try answerOf(siphon, client, "3"), &.{"result"}) != null);
    client.send("{\"id\":\"4\",\"method\":\"providers.list\"}");
    const listed = field(try answerOf(siphon, client, "4"), &.{ "result", "providers" }).?.array.items;
    try std.testing.expectEqualStrings("sign_in", listed[1].object.get("connects").?.string);

    // A sign-in sends the browser to the issuer with the host's address to come back to; one finished with a bad code
    // fails, and is spent.
    client.send("{\"id\":\"5\",\"method\":\"providers.sign-in\",\"params\":{\"provider\":\"signing\"}}");
    const begun = try answerOf(siphon, client, "5");
    try std.testing.expect(std.mem.endsWith(u8, field(begun, &.{ "result", "url" }).?.string, "redirect_uri=http://127.0.0.1:7600/auth/callback"));
    client.send("{\"id\":\"6\",\"method\":\"providers.finish-sign-in\",\"params\":{\"redirect\":\"http://127.0.0.1:7600/auth/callback?code=bad\"}}");
    try std.testing.expectEqualStrings("sign-in-failed", field(try answerOf(siphon, client, "6"), &.{ "error", "code" }).?.string);
    client.send("{\"id\":\"7\",\"method\":\"providers.finish-sign-in\",\"params\":{\"redirect\":\"http://127.0.0.1:7600/auth/callback?code=good\"}}");
    try std.testing.expectEqualStrings("no-sign-in", field(try answerOf(siphon, client, "7"), &.{ "error", "code" }).?.string);

    // Begun again, it finishes with a good code, from any client of the host's.
    client.send("{\"id\":\"8\",\"method\":\"providers.sign-in\",\"params\":{\"provider\":\"signing\"}}");
    _ = try answerOf(siphon, client, "8");
    const callback: Client = try .open(siphon, arena);
    callback.send("{\"id\":\"1\",\"method\":\"hello\",\"params\":{\"protocol\":1}}");
    callback.send("{\"id\":\"2\",\"method\":\"providers.finish-sign-in\",\"params\":{\"redirect\":\"http://127.0.0.1:7600/auth/callback?code=good\"}}");
    try std.testing.expectEqualStrings("signing", field(try answerOf(siphon, callback, "2"), &.{ "result", "provider" }).?.string);
    // A provider that takes a key is not signed in to.
    client.send("{\"id\":\"9\",\"method\":\"providers.sign-in\",\"params\":{\"provider\":\"fake\"}}");
    try std.testing.expectEqualStrings("invalid", field(try answerOf(siphon, client, "9"), &.{ "error", "code" }).?.string);
    try client.close();
    try callback.close();
}

/// Each name a folder was listed with, as `name kind`, and ` ignored` after one its repository's ignore files leave out.
fn namesOf(arena: Allocator, listed: std.json.Value) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (field(listed, &.{"entries"}).?.array.items) |entry| {
        const object = entry.object;
        const ignored = if (object.get("ignored").?.bool) " ignored" else "";
        try out.append(arena, try arena.print("{s} {s}{s}", .{ object.get("name").?.string, object.get("kind").?.string, ignored }));
    }
    return out.items;
}

/// Each path a search found, as `path kind`.
fn foundOf(arena: Allocator, searched: std.json.Value) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (field(searched, &.{"entries"}).?.array.items) |entry| {
        try out.append(arena, try arena.print("{s} {s}", .{ entry.object.get("path").?.string, entry.object.get("kind").?.string }));
    }
    return out.items;
}

/// A picture 64 pixels wide and 32 high, as a picture to fit.
const wide_png = testing.pngOf(64, 32);

/// A picture one pixel square, as PNG has it.
const one_pixel_png = "\x89PNG\x0d\x0a\x1a\x0a\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\x0aIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\x0d\x0a-\xb4\x00\x00\x00\x00IEND\xaeB`\x82";

test "a client lists a folder of the machine, reads a page of a file, and finds the paths under a folder that match, off the loop" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "project/.git", "project/src/components", "project/zig-out", "home" }) |folder| try tmp.dir.createDirPath(io, folder);
    const written = [_][2][]const u8{
        .{ "project/.gitignore", "zig-out/\n*.log\n" },
        .{ "project/README.md", "# Notes\nsecond line\n" },
        .{ "project/build.log", "noise\n" },
        .{ "project/src/main.zig", "pub fn main() void {}\n" },
        .{ "project/src/components/FileTree.tsx", "export {};\n" },
        .{ "project/src/pixel.png", one_pixel_png },
        .{ "project/src/wide.png", &wide_png },
        .{ "project/zig-out/out.bin", "x\x00y" },
        .{ "home/notes.txt", "home\n" },
    };
    for (written) |file| try tmp.dir.writeFile(io, .{ .sub_path = file[0], .data = file[1] });
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const project = try std.fs.path.join(arena, &.{ root, "project" });
    const home = try std.fs.path.join(arena, &.{ root, "home" });
    const machine = try testing.openLocalMachine();
    defer _ = @import("beak.zig").h.beak_close(machine);
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try Siphon.open(std.testing.allocator, .{ .io = io, .clock = clock.clock(), .machine = machine, .home = home }, .{});
    defer siphon.close();
    const client: Client = try .open(siphon, arena);
    client.send("{\"id\":\"1\",\"method\":\"hello\",\"params\":{\"protocol\":1}}");
    _ = try answerOf(siphon, client, "1");

    // A folder's names in order, each with what it names, and whether its repository's ignore files leave it out — in
    // a folder within the repository too, and everything within a folder they name; hidden ones only where asked for;
    // those a prefix begins; `~` is the home folder.
    try client.sendf("{{\"id\":\"2\",\"method\":\"files.list\",\"params\":{{\"path\":\"{s}\",\"hidden\":true}}}}", .{project});
    const listed = field(try answerOf(siphon, client, "2"), &.{"result"}).?;
    try std.testing.expectEqualStrings(project, field(listed, &.{"path"}).?.string);
    const names = [_][]const u8{ ".git directory ignored", ".gitignore file", "README.md file", "build.log file ignored", "src directory", "zig-out directory ignored" };
    try std.testing.expectEqualDeep(@as([]const []const u8, &names), try namesOf(arena, listed));
    try std.testing.expect(!field(listed, &.{"more"}).?.bool);
    try client.sendf("{{\"id\":\"2a\",\"method\":\"files.list\",\"params\":{{\"path\":\"{s}\"}}}}", .{project});
    const shown = [_][]const u8{ "README.md file", "build.log file ignored", "src directory", "zig-out directory ignored" };
    try std.testing.expectEqualDeep(@as([]const []const u8, &shown), try namesOf(arena, field(try answerOf(siphon, client, "2a"), &.{"result"}).?));
    try client.sendf("{{\"id\":\"2b\",\"method\":\"files.list\",\"params\":{{\"path\":\"{s}\",\"prefix\":\".git\",\"hidden\":true}}}}", .{project});
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ ".git directory ignored", ".gitignore file" }), try namesOf(arena, field(try answerOf(siphon, client, "2b"), &.{"result"}).?));
    try client.sendf("{{\"id\":\"3\",\"method\":\"files.list\",\"params\":{{\"path\":\"{s}/zig-out\"}}}}", .{project});
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"out.bin file ignored"}), try namesOf(arena, field(try answerOf(siphon, client, "3"), &.{"result"}).?));
    client.send("{\"id\":\"4\",\"method\":\"files.list\",\"params\":{\"path\":\"~\"}}");
    const at_home = field(try answerOf(siphon, client, "4"), &.{"result"}).?;
    try std.testing.expectEqualStrings(home, field(at_home, &.{"path"}).?.string);
    try std.testing.expectEqualStrings("notes.txt", field(at_home, &.{"entries"}).?.array.items[0].object.get("name").?.string);
    // A path is whole, refused before it runs where it is not; a file is no folder.
    client.send("{\"id\":\"5\",\"method\":\"files.list\",\"params\":{\"path\":\"src\"}}");
    try std.testing.expectEqualStrings("invalid", field(try answerOf(siphon, client, "5"), &.{ "error", "code" }).?.string);
    try client.sendf("{{\"id\":\"6\",\"method\":\"files.list\",\"params\":{{\"path\":\"{s}/README.md\"}}}}", .{project});
    try std.testing.expectEqualStrings("not-a-directory", field(try answerOf(siphon, client, "6"), &.{ "error", "code" }).?.string);

    // A page of a file: its lines, from the first asked for; an image as its bytes; a binary file as no more than that.
    try client.sendf("{{\"id\":\"7\",\"method\":\"files.read\",\"params\":{{\"path\":\"{s}/README.md\"}}}}", .{project});
    const page = field(try answerOf(siphon, client, "7"), &.{"result"}).?;
    try std.testing.expectEqualStrings("text", field(page, &.{"type"}).?.string);
    try std.testing.expectEqual(@as(i64, 2), field(page, &.{"line_count"}).?.integer);
    try std.testing.expectEqualStrings("second line", field(page, &.{"lines"}).?.array.items[1].string);
    try client.sendf("{{\"id\":\"8\",\"method\":\"files.read\",\"params\":{{\"path\":\"{s}/README.md\",\"offset\":2,\"limit\":1}}}}", .{project});
    const second = field(try answerOf(siphon, client, "8"), &.{"result"}).?;
    try std.testing.expectEqual(@as(i64, 2), field(second, &.{"from"}).?.integer);
    try std.testing.expectEqual(@as(usize, 1), field(second, &.{"lines"}).?.array.items.len);
    try client.sendf("{{\"id\":\"9\",\"method\":\"files.read\",\"params\":{{\"path\":\"{s}/src/pixel.png\"}}}}", .{project});
    const picture = field(try answerOf(siphon, client, "9"), &.{"result"}).?;
    try std.testing.expectEqualStrings("image/png", field(picture, &.{"media_type"}).?.string);
    try std.testing.expectEqualSlices(u8, one_pixel_png, (try imageOf(arena, picture)).bytes);
    // An image fitted to a box keeps its shape; read whole, it is as it is.
    try client.sendf("{{\"id\":\"9a\",\"method\":\"files.read\",\"params\":{{\"path\":\"{s}/src/wide.png\",\"box\":{{\"width_max\":48,\"height_max\":16}}}}}}", .{project});
    const small = field(try answerOf(siphon, client, "9a"), &.{"result"}).?;
    try std.testing.expectEqual(image.Size{ .width = 32, .height = 16 }, (try imageOf(arena, small)).size);
    try client.sendf("{{\"id\":\"9b\",\"method\":\"files.read\",\"params\":{{\"path\":\"{s}/src/wide.png\"}}}}", .{project});
    try std.testing.expectEqualSlices(u8, &wide_png, (try imageOf(arena, field(try answerOf(siphon, client, "9b"), &.{"result"}).?)).bytes);
    try client.sendf("{{\"id\":\"10\",\"method\":\"files.read\",\"params\":{{\"path\":\"{s}/zig-out/out.bin\"}}}}", .{project});
    try std.testing.expectEqualStrings("binary", field(try answerOf(siphon, client, "10"), &.{ "result", "type" }).?.string);
    try client.sendf("{{\"id\":\"11\",\"method\":\"files.read\",\"params\":{{\"path\":\"{s}/src\"}}}}", .{project});
    try std.testing.expectEqualStrings("is-a-directory", field(try answerOf(siphon, client, "11"), &.{ "error", "code" }).?.string);
    try client.sendf("{{\"id\":\"12\",\"method\":\"files.read\",\"params\":{{\"path\":\"{s}/nowhere.md\"}}}}", .{project});
    try std.testing.expectEqualStrings("not-found", field(try answerOf(siphon, client, "12"), &.{ "error", "code" }).?.string);

    // The files and folders under a folder that match, best first, those the ignore files name left out; asked for
    // nothing, the shortest paths first.
    try client.sendf("{{\"id\":\"13\",\"method\":\"files.search\",\"params\":{{\"path\":\"{s}\",\"query\":\"ft\"}}}}", .{project});
    try std.testing.expectEqualStrings("src/components/FileTree.tsx file", (try foundOf(arena, field(try answerOf(siphon, client, "13"), &.{"result"}).?))[0]);
    try client.sendf("{{\"id\":\"14\",\"method\":\"files.search\",\"params\":{{\"path\":\"{s}\",\"query\":\"comp\"}}}}", .{project});
    try std.testing.expectEqualStrings("src/components directory", (try foundOf(arena, field(try answerOf(siphon, client, "14"), &.{"result"}).?))[0]);
    try client.sendf("{{\"id\":\"15\",\"method\":\"files.search\",\"params\":{{\"path\":\"{s}\",\"query\":\"out\"}}}}", .{project});
    try std.testing.expectEqual(@as(usize, 0), (try foundOf(arena, field(try answerOf(siphon, client, "15"), &.{"result"}).?)).len);
    try client.sendf("{{\"id\":\"16\",\"method\":\"files.search\",\"params\":{{\"path\":\"{s}\",\"query\":\"\",\"limit\":2}}}}", .{project});
    const shortest = field(try answerOf(siphon, client, "16"), &.{"result"}).?;
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "src directory", "README.md file" }), try foundOf(arena, shortest));
    try std.testing.expect(field(shortest, &.{"truncated"}).?.bool);
    try client.close();
}

/// What a client was sent, kept till a test looks for it: a message found is taken, the others kept in the order they
/// came, with how many of them came before the one found last.
const Inbox = struct {
    client: Client,
    kept: std.ArrayList(std.json.Value) = .empty,
    before_found: usize = 0,

    /// The first message `matches` takes, of those kept and then of those sent as the loop is pumped for them.
    fn until(inbox: *Inbox, siphon: *Siphon, context: anytype, comptime matches: fn (@TypeOf(context), std.json.Value) bool) !std.json.Value {
        const Waiting = struct {
            inbox: *Inbox,
            context: @TypeOf(context),
            found: ?std.json.Value = null,

            fn arrived(waiting: *@This()) bool {
                const kept = &waiting.inbox.kept;
                kept.appendSlice(waiting.inbox.client.arena, waiting.inbox.client.taken() catch return false) catch return false;
                for (kept.items, 0..) |message, index| if (matches(waiting.context, message)) {
                    waiting.found = kept.orderedRemove(index);
                    waiting.inbox.before_found = index;
                    return true;
                };
                return false;
            }
        };
        var waiting: Waiting = .{ .inbox = inbox, .context = context };
        if (!waiting.arrived()) try testing.pumpUntil(siphon, &waiting, Waiting.arrived);
        return waiting.found.?;
    }

    /// Lets go of what was sent so far, kept or not yet taken: what a test looks for next comes of what it does next.
    fn forget(inbox: *Inbox) !void {
        _ = try inbox.client.taken();
        inbox.kept.clearRetainingCapacity();
    }

    /// The answer to the message `id`.
    fn answer(inbox: *Inbox, siphon: *Siphon, id: []const u8) !std.json.Value {
        return inbox.until(siphon, id, struct {
            fn matches(wanted: []const u8, message: std.json.Value) bool {
                const told = field(message, &.{"id"}) orelse return false;
                return told == .string and std.mem.eql(u8, told.string, wanted);
            }
        }.matches);
    }

    /// Whether a message `matches` takes came before the one found last.
    fn cameBefore(inbox: *const Inbox, context: anytype, comptime matches: fn (@TypeOf(context), std.json.Value) bool) bool {
        for (inbox.kept.items[0..inbox.before_found]) |message| if (matches(context, message)) return true;
        return false;
    }
};

/// What a terminal's event sends: its kind; of a list, how many terminals, and the first one's title; of a screen, its
/// rows; of output or a screen, its bytes.
const Told = struct {
    arena: Allocator,
    event: []const u8,
    count: ?usize = null,
    title: ?[]const u8 = null,
    rows: ?i64 = null,
    holding: ?[]const u8 = null,

    fn matches(told: Told, message: std.json.Value) bool {
        const event = field(message, &.{"event"}) orelse return false;
        if (!std.mem.eql(u8, event.string, told.event)) return false;
        if (told.count) |count| if (field(message, &.{"terminals"}).?.array.items.len != count) return false;
        if (told.title) |title| {
            const first = field(message, &.{"terminals"}).?.array.items[0];
            const named = field(first, &.{"title"}) orelse return false;
            if (!std.mem.eql(u8, named.string, title)) return false;
        }
        if (told.rows) |rows| if (field(message, &.{"rows"}).?.integer != rows) return false;
        const wanted = told.holding orelse return true;
        const encoded = (field(message, &.{"data"}) orelse field(message, &.{"screen"}).?).string;
        const bytes = told.arena.alloc(u8, std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return false) catch return false;
        std.base64.standard.Decoder.decode(bytes, encoded) catch return false;
        return std.mem.indexOf(u8, bytes, wanted) != null;
    }
};

test "a thread's terminals: opened in its folder and numbered, told with their titles, sized to their smallest view, gone as their programs end or they close" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const machine = try testing.openLocalMachine();
    defer _ = @import("beak.zig").h.beak_close(machine);
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try Siphon.open(std.testing.allocator, .{ .io = std.testing.io, .clock = clock.clock(), .machine = machine, .home = "/", .shell = "/bin/sh" }, .{});
    defer siphon.close();
    const thread = try threads.create(siphon.runtime, arena, .{ .workspace = workspace }, "create");
    const client: Client = try .open(siphon, arena);
    client.send("{\"id\":\"1\",\"method\":\"hello\",\"params\":{\"protocol\":1}}");
    _ = try answerOf(siphon, client, "1");
    var inbox: Inbox = .{ .client = client };

    // A thread followed tells of its terminals: none; then the one opened, told before the opening is answered.
    try client.sendf("{{\"id\":\"2\",\"method\":\"threads.follow\",\"params\":{{\"thread\":\"{s}\"}}}}", .{thread});
    _ = try inbox.until(siphon, Told{ .arena = arena, .event = "terminals", .count = 0 }, Told.matches);
    try client.sendf("{{\"id\":\"3\",\"method\":\"terminals.open\",\"params\":{{\"thread\":\"{s}\",\"rows\":24,\"cols\":80}}}}", .{thread});
    const terminal = field(try inbox.answer(siphon, "3"), &.{ "result", "terminal" }).?.string;
    try std.testing.expect(inbox.cameBefore(Told{ .arena = arena, .event = "terminals", .count = 1 }, Told.matches));

    // Followed, it is drawn first, at its size; then what it writes comes as it writes it, in the thread's folder.
    try client.sendf("{{\"id\":\"4\",\"method\":\"terminals.follow\",\"params\":{{\"terminal\":\"{s}\",\"rows\":24,\"cols\":80}}}}", .{terminal});
    _ = try inbox.until(siphon, Told{ .arena = arena, .event = "terminal-screen", .rows = 24 }, Told.matches);
    try std.testing.expect(field(try inbox.answer(siphon, "4"), &.{"result"}).? == .object);
    try client.sendf("{{\"id\":\"5\",\"method\":\"terminals.write\",\"params\":{{\"terminal\":\"{s}\",\"data\":\"echo made-$((40+2)) in $(pwd)\\n\"}}}}", .{terminal});
    _ = try inbox.until(siphon, Told{ .arena = arena, .event = "terminal-output", .holding = try arena.print("made-42 in {s}", .{workspace}) }, Told.matches);

    // The title its program sets is told with it.
    try client.sendf("{{\"id\":\"6\",\"method\":\"terminals.write\",\"params\":{{\"terminal\":\"{s}\",\"data\":\"printf '\\\\033]2;building\\\\007'\\n\"}}}}", .{terminal});
    _ = try inbox.until(siphon, Told{ .arena = arena, .event = "terminals", .title = "building" }, Told.matches);

    // Another client's smaller view sizes it smaller, drawn again for both; that client gone, it grows back.
    const other: Client = try .open(siphon, arena);
    other.send("{\"id\":\"1\",\"method\":\"hello\",\"params\":{\"protocol\":1}}");
    var other_inbox: Inbox = .{ .client = other };
    _ = try other_inbox.answer(siphon, "1");
    try other.sendf("{{\"id\":\"2\",\"method\":\"terminals.follow\",\"params\":{{\"terminal\":\"{s}\",\"rows\":20,\"cols\":60}}}}", .{terminal});
    _ = try other_inbox.until(siphon, Told{ .arena = arena, .event = "terminal-screen", .rows = 20 }, Told.matches);
    _ = try inbox.until(siphon, Told{ .arena = arena, .event = "terminal-screen", .rows = 20 }, Told.matches);
    try other.close();
    _ = try inbox.until(siphon, Told{ .arena = arena, .event = "terminal-screen", .rows = 24 }, Told.matches);

    // A second terminal takes the next number; its program's end takes it away.
    try client.sendf("{{\"id\":\"7\",\"method\":\"terminals.open\",\"params\":{{\"thread\":\"{s}\",\"rows\":24,\"cols\":80}}}}", .{thread});
    const second = field(try inbox.answer(siphon, "7"), &.{ "result", "terminal" }).?.string;
    const two = try inbox.until(siphon, Told{ .arena = arena, .event = "terminals", .count = 2 }, Told.matches);
    try std.testing.expectEqual(@as(i64, 2), field(field(two, &.{"terminals"}).?.array.items[1], &.{"number"}).?.integer);
    try client.sendf("{{\"id\":\"8\",\"method\":\"terminals.write\",\"params\":{{\"terminal\":\"{s}\",\"data\":\"exit\\n\"}}}}", .{second});
    _ = try inbox.until(siphon, Told{ .arena = arena, .event = "terminals", .count = 1 }, Told.matches);

    // A view of a terminal not followed is refused, as is an empty one; closed, a terminal is gone from its thread and
    // from the terminals.
    try client.sendf("{{\"id\":\"9\",\"method\":\"terminals.unfollow\",\"params\":{{\"terminal\":\"{s}\"}}}}", .{terminal});
    _ = try inbox.answer(siphon, "9");
    try client.sendf("{{\"id\":\"10\",\"method\":\"terminals.resize\",\"params\":{{\"terminal\":\"{s}\",\"rows\":30,\"cols\":100}}}}", .{terminal});
    try std.testing.expectEqualStrings("not-followed", field(try inbox.answer(siphon, "10"), &.{ "error", "code" }).?.string);
    try client.sendf("{{\"id\":\"13\",\"method\":\"terminals.follow\",\"params\":{{\"terminal\":\"{s}\",\"rows\":0,\"cols\":80}}}}", .{terminal});
    try std.testing.expectEqualStrings("invalid", field(try inbox.answer(siphon, "13"), &.{ "error", "code" }).?.string);
    try client.sendf("{{\"id\":\"11\",\"method\":\"terminals.close\",\"params\":{{\"terminal\":\"{s}\"}}}}", .{terminal});
    _ = try inbox.until(siphon, Told{ .arena = arena, .event = "terminals", .count = 0 }, Told.matches);
    try client.sendf("{{\"id\":\"12\",\"method\":\"terminals.write\",\"params\":{{\"terminal\":\"{s}\",\"data\":\"x\"}}}}", .{terminal});
    try std.testing.expectEqualStrings("no-such-terminal", field(try inbox.answer(siphon, "12"), &.{ "error", "code" }).?.string);
    try client.close();
}

/// Runs git with `args` in `folder` for a test's repository, as a person would, its commits by one author.
fn gitIn(arena: Allocator, folder: []const u8, args: []const []const u8) !void {
    const Machine = @import("machine.zig");
    const handle = try testing.openLocalMachine();
    defer _ = @import("beak.zig").h.beak_close(handle);
    const machine = try Machine.open(.{ .handle = handle }, .{ .base = .{ .workspace = folder, .home = null } });
    defer machine.close();
    var waits: runtime_.Waits = .{};
    defer waits.close();
    const argv = try std.mem.concat(arena, []const u8, &.{ &.{ "git", "-c", "user.name=Tester", "-c", "user.email=tester@example.com", "-c", "commit.gpgsign=false" }, args });
    const ran = try machine.run(std.testing.io, arena, &waits, .{ .argv = argv, .cwd = folder });
    if (ran.ended != .code or ran.ended.code != 0) {
        std.debug.print("git {s}: {s}\n", .{ args[0], ran.errors });
        return error.GitFailed;
    }
}

/// The files of a changes' answer, each as "status path" and its counts.
fn changedOf(arena: Allocator, answer: std.json.Value) ![]const []const u8 {
    var shown: std.ArrayList([]const u8) = .empty;
    for (field(answer, &.{ "result", "files" }).?.array.items) |file| {
        const old = if (field(file, &.{"old_path"})) |from| try arena.print(" from {s}", .{from.string}) else "";
        const added = if (field(file, &.{"additions"})) |count| count.integer else -1;
        const deleted = if (field(file, &.{"deletions"})) |count| count.integer else -1;
        try shown.append(arena, try arena.print("{s} {s}{s} +{d} -{d}", .{ field(file, &.{"status"}).?.string, field(file, &.{"path"}).?.string, old, added, deleted }));
    }
    return shown.items;
}

test "a client reads a repository's changes: not yet committed, a branch's against its base, or a commit's; a file's patch, its two versions, the branch's commits" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo");
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const repo = try std.fs.path.join(arena, &.{ root, "repo" });
    // main: one commit; feature: a second; then the working tree's own — a line more, a rename staged, a file untracked.
    try gitIn(arena, repo, &.{ "init", "-q", "-b", "main" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/a.txt", .data = "one\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.gitignore", .data = "*.log\n" });
    try gitIn(arena, repo, &.{ "add", "." });
    try gitIn(arena, repo, &.{ "commit", "-q", "-m", "first" });
    try gitIn(arena, repo, &.{ "checkout", "-q", "-b", "feature" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/a.txt", .data = "one\ntwo\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/b.txt", .data = "bee\n" });
    try gitIn(arena, repo, &.{ "add", "." });
    try gitIn(arena, repo, &.{ "commit", "-q", "-m", "second" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/a.txt", .data = "one\ntwo\nthree\n" });
    try gitIn(arena, repo, &.{ "mv", "b.txt", "c.txt" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/u.txt", .data = "x\ny" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/noise.log", .data = "left out\n" });

    const machine = try testing.openLocalMachine();
    defer _ = @import("beak.zig").h.beak_close(machine);
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try Siphon.open(std.testing.allocator, .{ .io = io, .clock = clock.clock(), .machine = machine, .home = root }, .{});
    defer siphon.close();
    const client: Client = try .open(siphon, arena);
    client.send("{\"id\":\"1\",\"method\":\"hello\",\"params\":{\"protocol\":1}}");
    _ = try answerOf(siphon, client, "1");

    // The repository a folder is in, its branch and the branch its work was taken from; none for a folder in none.
    try client.sendf("{{\"id\":\"2\",\"method\":\"git.repository\",\"params\":{{\"path\":\"{s}\"}}}}", .{repo});
    const found = field(try answerOf(siphon, client, "2"), &.{ "result", "repository" }).?;
    try std.testing.expectEqualStrings(repo, field(found, &.{"root"}).?.string);
    try std.testing.expectEqualStrings("feature", field(found, &.{"branch"}).?.string);
    try std.testing.expectEqualStrings("main", field(found, &.{"base"}).?.string);
    // The machine's root, in no repository; a test's own folder is in the one it is built in.
    client.send("{\"id\":\"3\",\"method\":\"git.repository\",\"params\":{\"path\":\"/\"}}");
    const none = try answerOf(siphon, client, "3");
    try std.testing.expect(field(none, &.{"result"}) != null and field(none, &.{ "result", "repository" }) == null);

    // Not yet committed: the line more, the rename, the untracked file, the ignored one left out.
    try client.sendf("{{\"id\":\"4\",\"method\":\"git.changes\",\"params\":{{\"path\":\"{s}\",\"scope\":{{\"type\":\"uncommitted\"}}}}}}", .{repo});
    const uncommitted = try answerOf(siphon, client, "4");
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "modified a.txt +1 -0", "renamed c.txt from b.txt +0 -0", "untracked u.txt +2 -0" }), try changedOf(arena, uncommitted));
    const comparison = field(uncommitted, &.{ "result", "comparison" }).?;
    try std.testing.expect(field(comparison, &.{"new"}) == null);

    // The branch's, against where it parted from main: both its commit and the working tree.
    try client.sendf("{{\"id\":\"5\",\"method\":\"git.changes\",\"params\":{{\"path\":\"{s}\",\"scope\":{{\"type\":\"branch\"}}}}}}", .{repo});
    const branch = try answerOf(siphon, client, "5");
    try std.testing.expectEqualStrings("main", field(branch, &.{ "result", "base" }).?.string);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "modified a.txt +2 -0", "added c.txt +1 -0", "untracked u.txt +2 -0" }), try changedOf(arena, branch));

    // A file's patch, and its two versions, between the trees the changes were told between.
    const old = field(comparison, &.{"old"}).?.string;
    try client.sendf("{{\"id\":\"6\",\"method\":\"git.patch\",\"params\":{{\"path\":\"{s}\",\"comparison\":{{\"old\":\"{s}\"}},\"file\":{{\"path\":\"a.txt\",\"status\":\"modified\"}}}}}}", .{ repo, old });
    const patched = field(try answerOf(siphon, client, "6"), &.{ "result", "patch" }).?.string;
    try std.testing.expect(std.mem.indexOf(u8, patched, "@@ -1,2 +1,3 @@") != null);
    try std.testing.expect(std.mem.indexOf(u8, patched, "\n+three\n") != null);
    try client.sendf("{{\"id\":\"7\",\"method\":\"git.patch\",\"params\":{{\"path\":\"{s}\",\"comparison\":{{\"old\":\"{s}\"}},\"file\":{{\"path\":\"u.txt\",\"status\":\"untracked\"}}}}}}", .{ repo, old });
    try std.testing.expect(std.mem.indexOf(u8, field(try answerOf(siphon, client, "7"), &.{ "result", "patch" }).?.string, "+x\n+y\n") != null);
    try client.sendf("{{\"id\":\"8\",\"method\":\"git.versions\",\"params\":{{\"path\":\"{s}\",\"comparison\":{{\"old\":\"{s}\"}},\"file\":{{\"path\":\"a.txt\",\"status\":\"modified\"}}}}}}", .{ repo, old });
    const versions = try answerOf(siphon, client, "8");
    try std.testing.expectEqualStrings("one\ntwo\n", field(versions, &.{ "result", "old" }).?.string);
    try std.testing.expectEqualStrings("one\ntwo\nthree\n", field(versions, &.{ "result", "new" }).?.string);

    // The branch's commits; one picked, its own changes against its parent.
    try client.sendf("{{\"id\":\"9\",\"method\":\"git.commits\",\"params\":{{\"path\":\"{s}\"}}}}", .{repo});
    const listed = field(try answerOf(siphon, client, "9"), &.{ "result", "commits" }).?.array.items;
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqualStrings("second", field(listed[0], &.{"subject"}).?.string);
    try client.sendf("{{\"id\":\"10\",\"method\":\"git.changes\",\"params\":{{\"path\":\"{s}\",\"scope\":{{\"type\":\"commit\",\"commit\":\"{s}\"}}}}}}", .{ repo, field(listed[0], &.{"commit"}).?.string });
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "modified a.txt +1 -0", "added b.txt +1 -0" }), try changedOf(arena, try answerOf(siphon, client, "10")));

    // A tree named by what is no object's id is refused, never taken as an option.
    try client.sendf("{{\"id\":\"11\",\"method\":\"git.patch\",\"params\":{{\"path\":\"{s}\",\"comparison\":{{\"old\":\"--output=/tmp/x\"}},\"file\":{{\"path\":\"a.txt\",\"status\":\"modified\"}}}}}}", .{repo});
    try std.testing.expectEqualStrings("invalid", field(try answerOf(siphon, client, "11"), &.{ "error", "code" }).?.string);
    try client.close();
}

/// A thread's pages as a client is told of them: how many, and of the one at `index`, what it is called, where it is
/// — the start of its address — whether it can go back and forward, and the message of the dialog that holds it, empty
/// for none, where each is given.
const PagesTold = struct {
    count: usize,
    index: usize = 0,
    title: ?[]const u8 = null,
    url: ?[]const u8 = null,
    back: ?bool = null,
    forward: ?bool = null,
    dialog: ?[]const u8 = null,

    fn matches(told: PagesTold, message: std.json.Value) bool {
        const event = field(message, &.{"event"}) orelse return false;
        if (!std.mem.eql(u8, event.string, "pages")) return false;
        const listed = field(message, &.{"pages"}).?.array.items;
        if (listed.len != told.count) return false;
        if (told.count == 0) return true;
        const page = listed[told.index];
        if (told.title) |title| if (!std.mem.eql(u8, field(page, &.{"title"}).?.string, title)) return false;
        if (told.url) |url| if (!std.mem.startsWith(u8, field(page, &.{"url"}).?.string, url)) return false;
        if (told.back) |back| if (field(page, &.{"back"}).?.bool != back) return false;
        if (told.forward) |forward| if (field(page, &.{"forward"}).?.bool != forward) return false;
        if (told.dialog) |dialog| {
            const shown = field(page, &.{ "dialog", "message" });
            if (dialog.len == 0) return shown == null;
            if (shown == null or !std.mem.eql(u8, shown.?.string, dialog)) return false;
        }
        return true;
    }

    /// The id of the page at `index` of the pages `message` tells of.
    fn idOf(message: std.json.Value, index: usize) []const u8 {
        return field(field(message, &.{"pages"}).?.array.items[index], &.{"id"}).?.string;
    }
};

/// A frame of the page `page`.
fn isFrameOf(page: []const u8, message: std.json.Value) bool {
    const event = field(message, &.{"event"}) orelse return false;
    if (!std.mem.eql(u8, event.string, "page-frame")) return false;
    return std.mem.eql(u8, field(message, &.{"page"}).?.string, page);
}

test "a thread's pages in the browser: opened, painted for those that follow them, clicked and typed into, a dialog answered, navigated and taken back, a page a page opens a page of the thread, one that closes itself gone" {
    const chromium = testing.chromium() orelse return error.SkipZigTest;
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const profile = try std.fs.path.join(arena, &.{ root, "profile" });
    const machine = try testing.openLocalMachine();
    defer _ = @import("beak.zig").h.beak_close(machine);
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try Siphon.open(std.testing.allocator, .{ .io = std.testing.io, .clock = clock.clock(), .machine = machine, .home = root, .browser = chromium, .browser_profile = profile }, .{});
    defer siphon.close();
    const thread = try threads.create(siphon.runtime, arena, .{ .workspace = root }, "create");
    const client: Client = try .open(siphon, arena);
    client.send("{\"id\":\"1\",\"method\":\"hello\",\"params\":{\"protocol\":1}}");
    var inbox: Inbox = .{ .client = client };
    _ = try inbox.answer(siphon, "1");

    // Opened for a thread followed at an address, the page is told of, its history begun there; followed, it is painted.
    try client.sendf("{{\"id\":\"2\",\"method\":\"threads.follow\",\"params\":{{\"thread\":\"{s}\"}}}}", .{thread});
    _ = try inbox.until(siphon, PagesTold{ .count = 0 }, PagesTold.matches);
    const first = "data:text/html,<title>First</title><button onclick=\"document.title='clicked'\" style=\"position:fixed;left:0;top:0;width:200px;height:100px\">go</button><input id=i oninput=\"document.title=this.value\" style=\"position:fixed;left:0;top:200px\"><a target=_blank href=\"about:blank%23popup\" style=\"position:fixed;left:0;top:300px;width:200px;height:50px;display:block\">open</a><button onclick=\"alert('hey')\" style=\"position:fixed;left:300px;top:0;width:100px;height:50px\">alert</button>";
    try client.sendf("{{\"id\":\"3\",\"method\":\"browser.open\",\"params\":{{\"thread\":\"{s}\",\"url\":{f},\"width\":640,\"height\":480}}}}", .{ thread, std.json.fmt(first, .{}) });
    const page = field(try inbox.answer(siphon, "3"), &.{ "result", "page" }).?.string;
    _ = try inbox.until(siphon, PagesTold{ .count = 1, .title = "First", .back = false, .forward = false }, PagesTold.matches);
    try client.sendf("{{\"id\":\"4\",\"method\":\"browser.follow\",\"params\":{{\"page\":\"{s}\",\"width\":640,\"height\":480}}}}", .{page});
    const frame = try inbox.until(siphon, page, isFrameOf);
    try std.testing.expect(std.mem.startsWith(u8, field(frame, &.{"data"}).?.string, "/9j/"));
    try std.testing.expectEqual(@as(i64, 640), field(frame, &.{"width"}).?.integer);

    // Clicked where its button is, and typed into its field, as the person does it, its words chosen all at once.
    try client.sendf("{{\"id\":\"5\",\"method\":\"browser.mouse\",\"params\":{{\"page\":\"{s}\",\"event\":{{\"type\":\"down\",\"x\":50,\"y\":50,\"button\":\"left\",\"buttons\":1,\"clicks\":1}}}}}}", .{page});
    try client.sendf("{{\"id\":\"6\",\"method\":\"browser.mouse\",\"params\":{{\"page\":\"{s}\",\"event\":{{\"type\":\"up\",\"x\":50,\"y\":50,\"button\":\"left\",\"clicks\":1}}}}}}", .{page});
    _ = try inbox.until(siphon, PagesTold{ .count = 1, .title = "clicked" }, PagesTold.matches);
    try client.sendf("{{\"id\":\"7\",\"method\":\"browser.mouse\",\"params\":{{\"page\":\"{s}\",\"event\":{{\"type\":\"down\",\"x\":20,\"y\":210,\"button\":\"left\",\"buttons\":1,\"clicks\":1}}}}}}", .{page});
    try client.sendf("{{\"id\":\"8\",\"method\":\"browser.mouse\",\"params\":{{\"page\":\"{s}\",\"event\":{{\"type\":\"up\",\"x\":20,\"y\":210,\"button\":\"left\",\"clicks\":1}}}}}}", .{page});
    try client.sendf("{{\"id\":\"9\",\"method\":\"browser.text\",\"params\":{{\"page\":\"{s}\",\"text\":\"typed\"}}}}", .{page});
    _ = try inbox.until(siphon, PagesTold{ .count = 1, .title = "typed" }, PagesTold.matches);
    try client.sendf("{{\"id\":\"10\",\"method\":\"browser.key\",\"params\":{{\"page\":\"{s}\",\"event\":{{\"type\":\"down\",\"key\":\"a\",\"code\":\"KeyA\",\"modifiers\":4,\"key_code\":65,\"commands\":[\"selectAll\"]}}}}}}", .{page});
    try client.sendf("{{\"id\":\"11\",\"method\":\"browser.text\",\"params\":{{\"page\":\"{s}\",\"text\":\"all of it\"}}}}", .{page});
    _ = try inbox.until(siphon, PagesTold{ .count = 1, .title = "all of it" }, PagesTold.matches);

    // A dialog it opens is told of, and gone once the person answers it.
    try client.sendf("{{\"id\":\"12\",\"method\":\"browser.mouse\",\"params\":{{\"page\":\"{s}\",\"event\":{{\"type\":\"down\",\"x\":350,\"y\":25,\"button\":\"left\",\"buttons\":1,\"clicks\":1}}}}}}", .{page});
    try client.sendf("{{\"id\":\"13\",\"method\":\"browser.mouse\",\"params\":{{\"page\":\"{s}\",\"event\":{{\"type\":\"up\",\"x\":350,\"y\":25,\"button\":\"left\",\"clicks\":1}}}}}}", .{page});
    _ = try inbox.until(siphon, PagesTold{ .count = 1, .dialog = "hey" }, PagesTold.matches);
    try client.sendf("{{\"id\":\"14\",\"method\":\"browser.dialog\",\"params\":{{\"page\":\"{s}\",\"accept\":true}}}}", .{page});
    _ = try inbox.until(siphon, PagesTold{ .count = 1, .dialog = "" }, PagesTold.matches);

    // Its link to a new window clicked, the page it opens is a page of the thread; closed, it is gone.
    try client.sendf("{{\"id\":\"15\",\"method\":\"browser.mouse\",\"params\":{{\"page\":\"{s}\",\"event\":{{\"type\":\"down\",\"x\":50,\"y\":320,\"button\":\"left\",\"buttons\":1,\"clicks\":1}}}}}}", .{page});
    try client.sendf("{{\"id\":\"16\",\"method\":\"browser.mouse\",\"params\":{{\"page\":\"{s}\",\"event\":{{\"type\":\"up\",\"x\":50,\"y\":320,\"button\":\"left\",\"clicks\":1}}}}}}", .{page});
    const opened = try inbox.until(siphon, PagesTold{ .count = 2, .index = 1, .url = "about:blank#popup" }, PagesTold.matches);
    try inbox.forget();
    try client.sendf("{{\"id\":\"17\",\"method\":\"browser.close\",\"params\":{{\"page\":\"{s}\"}}}}", .{PagesTold.idOf(opened, 1)});
    _ = try inbox.until(siphon, PagesTold{ .count = 1, .title = "all of it" }, PagesTold.matches);

    // Navigated, it can go back; taken back, it is where it was, and can go forward.
    try client.sendf("{{\"id\":\"18\",\"method\":\"browser.navigate\",\"params\":{{\"page\":\"{s}\",\"url\":\"data:text/html,<title>Second</title>\"}}}}", .{page});
    _ = try inbox.until(siphon, PagesTold{ .count = 1, .title = "Second", .back = true }, PagesTold.matches);
    try client.sendf("{{\"id\":\"19\",\"method\":\"browser.back\",\"params\":{{\"page\":\"{s}\"}}}}", .{page});
    _ = try inbox.until(siphon, PagesTold{ .count = 1, .url = "data:text/html,<title>First</title>", .back = false, .forward = true }, PagesTold.matches);

    // A page that closes itself is gone from its thread.
    const closing = "data:text/html,<title>Closing</title><button onclick=\"window.close()\" style=\"position:fixed;left:0;top:0;width:200px;height:100px\">close</button>";
    try client.sendf("{{\"id\":\"20\",\"method\":\"browser.open\",\"params\":{{\"thread\":\"{s}\",\"url\":{f},\"width\":640,\"height\":480}}}}", .{ thread, std.json.fmt(closing, .{}) });
    const second = field(try inbox.answer(siphon, "20"), &.{ "result", "page" }).?.string;
    try client.sendf("{{\"id\":\"21\",\"method\":\"browser.follow\",\"params\":{{\"page\":\"{s}\",\"width\":640,\"height\":480}}}}", .{second});
    _ = try inbox.until(siphon, PagesTold{ .count = 2, .index = 1, .title = "Closing" }, PagesTold.matches);
    _ = try inbox.until(siphon, second, isFrameOf);
    try inbox.forget();
    try client.sendf("{{\"id\":\"22\",\"method\":\"browser.mouse\",\"params\":{{\"page\":\"{s}\",\"event\":{{\"type\":\"down\",\"x\":50,\"y\":50,\"button\":\"left\",\"buttons\":1,\"clicks\":1}}}}}}", .{second});
    try client.sendf("{{\"id\":\"23\",\"method\":\"browser.mouse\",\"params\":{{\"page\":\"{s}\",\"event\":{{\"type\":\"up\",\"x\":50,\"y\":50,\"button\":\"left\",\"clicks\":1}}}}}}", .{second});
    _ = try inbox.until(siphon, PagesTold{ .count = 1 }, PagesTold.matches);

    // Closed, it is gone from its thread.
    try inbox.forget();
    try client.sendf("{{\"id\":\"24\",\"method\":\"browser.close\",\"params\":{{\"page\":\"{s}\"}}}}", .{page});
    _ = try inbox.until(siphon, PagesTold{ .count = 0 }, PagesTold.matches);
    try client.close();
}

test "a thread a client makes belongs to the repository its workspace is in, and what the person granted a project is listed and taken back" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo/work");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const machine = try testing.openLocalMachine();
    defer _ = @import("beak.zig").h.beak_close(machine);
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try Siphon.open(std.testing.allocator, .{ .io = std.testing.io, .clock = clock.clock(), .machine = machine }, .{});
    defer siphon.close();
    const client: Client = try .open(siphon, arena);
    client.send("{\"id\":\"1\",\"method\":\"hello\",\"params\":{\"protocol\":1}}");
    _ = try answerOf(siphon, client, "1");

    // Within a repository, the project is the repository's root.
    const repository = try std.fs.path.join(arena, &.{ root, "repo" });
    try client.sendf("{{\"id\":\"2\",\"method\":\"threads.create\",\"params\":{{\"manifest\":{{\"workspace\":\"{s}/work\"}},\"operation\":\"c1\"}}}}", .{repository});
    const tid = field(try answerOf(siphon, client, "2"), &.{ "result", "thread" }).?.string;
    try std.testing.expectEqualStrings(repository, (try threads.manifestOf(siphon.runtime.volume, &arena, try threads.pathOf(arena, tid))).project.?);

    // A project's grants are listed by its folder; one taken back leaves the rest.
    const permissions = @import("tools.zig").permissions;
    var changes: @import("runtime.zig").Changes = .{ .arena = arena };
    try permissions.grant(&changes, arena, .{ .folder = repository }, .command, &.{ "npm test *", "git push *" });
    _ = try siphon.runtime.commit(&changes);
    client.send("{\"id\":\"4\",\"method\":\"grants.list\"}");
    const listed = field(try answerOf(siphon, client, "4"), &.{ "result", "grants" }).?.array.items;
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqualStrings(repository, field(listed[0], &.{"folder"}).?.string);
    try std.testing.expectEqual(@as(usize, 2), field(listed[0], &.{"allow"}).?.array.items.len);
    try client.sendf("{{\"id\":\"5\",\"method\":\"grants.revoke\",\"params\":{{\"folder\":\"{s}\",\"action\":\"command\",\"pattern\":\"git push *\"}}}}", .{repository});
    _ = try answerOf(siphon, client, "5");
    const left = try permissions.grantsOf(siphon.runtime, arena, repository);
    try std.testing.expectEqual(@as(usize, 1), left.allow.len);
    try std.testing.expectEqualStrings("npm test *", left.allow[0].pattern);
    try client.close();
}
