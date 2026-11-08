//! A host's WebSocket answered from a recording, for tests. Each socket opened is matched, in order, with the next
//! recorded one by its address and the headers the recording names, and plays its steps: the peer's messages are given
//! as they come, up to the next message the client is to send, which the client's must equal — JSON as JSON, bytes kept
//! as `{"base64": ...}` as bytes — and the peer closes the socket where the recording says. A receive with nothing to
//! give waits out its wait on the test's clock. What the recording does not expect fails as `Transport`, with why in
//! `mismatch`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("json.zig");
const http = @import("http.zig");
const websocket = @import("websocket.zig");

/// A step of a recorded socket: a message the client sent, one its peer sent, or its peer closing it.
pub const Step = struct {
    client: ?std.json.Value = null,
    server: ?std.json.Value = null,
    close: ?enum { server } = null,
};

/// A socket as it was recorded: its address, the headers a test checks, and its steps in order.
pub const RecordedSocket = struct {
    url: []const u8,
    /// Headers it was opened with, by name in any case; others are not checked.
    headers: ?std.json.ArrayHashMap([]const u8) = null,
    steps: []const Step,
};

pub const SocketReplay = struct {
    /// Where everything the replay keeps lives: a test's arena.
    arena: Allocator,
    recorded: []const RecordedSocket,
    /// The sockets opened, in order, with their headers as they were opened.
    opened: std.ArrayList(websocket.Opening) = .empty,
    played: std.ArrayList(*Played) = .empty,
    /// The test's clock, in milliseconds, which a wait that nothing ends moves on; none, a wait ends at once.
    clock_ms: ?*i64 = null,
    /// Why the last thing refused was not the one expected.
    mismatch: ?[]const u8 = null,

    pub fn init(arena: Allocator, recorded: []const RecordedSocket) SocketReplay {
        return .{ .arena = arena, .recorded = recorded };
    }

    pub fn connector(replay: *SocketReplay) websocket.Connector {
        return .{ .context = replay, .vtable = &.{ .connect = connect } };
    }

    /// How many recorded steps no socket played, those of the sockets never opened among them.
    pub fn unplayed(replay: *const SocketReplay) usize {
        var count: usize = 0;
        for (replay.played.items) |played| count += played.recorded.steps.len - played.step;
        for (replay.recorded[replay.played.items.len..]) |recorded| count += @max(recorded.steps.len, 1);
        return count;
    }

    fn refuse(replay: *SocketReplay, comptime format: []const u8, arguments: anytype) (websocket.Error || Allocator.Error) {
        replay.mismatch = try std.fmt.allocPrint(replay.arena, format, arguments);
        return error.Transport;
    }

    fn connect(context: *anyopaque, opening: websocket.Opening) (websocket.Error || Allocator.Error)!websocket.Socket {
        const replay: *SocketReplay = @ptrCast(@alignCast(context));
        const headers = try replay.arena.alloc(http.Header, opening.headers.len);
        for (opening.headers, headers) |header, *copy| copy.* = .{ .name = try replay.arena.dupe(u8, header.name), .value = try replay.arena.dupe(u8, header.value) };
        try replay.opened.append(replay.arena, .{ .url = try replay.arena.dupe(u8, opening.url), .headers = headers });
        const number = replay.opened.items.len;
        if (replay.played.items.len == replay.recorded.len) return replay.refuse("socket {d}, {s}, comes after the recording's last", .{ number, opening.url });
        const recorded = replay.recorded[replay.played.items.len];
        if (!std.mem.eql(u8, recorded.url, opening.url)) return replay.refuse("socket {d}: {s} was opened where {s} was recorded", .{ number, opening.url, recorded.url });
        if (recorded.headers) |expected| {
            var it = expected.map.iterator();
            while (it.next()) |header| {
                const given = http.find(opening.headers, header.key_ptr.*);
                if (given == null or !std.mem.eql(u8, given.?, header.value_ptr.*)) {
                    return replay.refuse("socket {d}: the header {s} was {?s} where {s} was recorded", .{ number, header.key_ptr.*, given, header.value_ptr.* });
                }
            }
        }
        const played = try replay.arena.create(Played);
        played.* = .{ .replay = replay, .recorded = recorded };
        try played.play();
        try replay.played.append(replay.arena, played);
        return .{ .context = played, .vtable = &.{ .send = Played.send, .receive = Played.receive, .close = Played.close, .deinit = Played.deinit } };
    }
};

/// A socket that plays a recorded one's steps: the peer's, up to the client's next, are given as they come.
const Played = struct {
    replay: *SocketReplay,
    recorded: RecordedSocket,
    /// The next step not played.
    step: usize = 0,
    /// The peer's messages played and not yet received, and whether the peer then closed the socket.
    given: std.ArrayList(std.json.Value) = .empty,
    taken: usize = 0,
    peer_closed: bool = false,
    /// Whether the client closed it.
    closed: bool = false,

    fn current(played: *const Played) ?Step {
        return if (played.step < played.recorded.steps.len) played.recorded.steps[played.step] else null;
    }

    /// Gives the peer's messages up to the next the client is to send, closing where the recording does.
    fn play(played: *Played) Allocator.Error!void {
        while (played.current()) |step| {
            if (step.client != null or played.peer_closed) return;
            played.step += 1;
            if (step.close != null) played.peer_closed = true else if (step.server) |message| try played.given.append(played.replay.arena, message);
        }
    }

    fn send(context: *anyopaque, message: websocket.Message) websocket.Error!void {
        const played: *Played = @ptrCast(@alignCast(context));
        return played.check(message) catch |err| switch (err) {
            error.OutOfMemory => error.Transport,
            else => |refused| refused,
        };
    }

    fn check(played: *Played, message: websocket.Message) (websocket.Error || Allocator.Error)!void {
        const replay = played.replay;
        const url = played.recorded.url;
        const shown = switch (message) {
            .text => |text| text,
            .binary => |bytes| try std.fmt.allocPrint(replay.arena, "{d} bytes", .{bytes.len}),
        };
        if (played.closed or played.peer_closed) return replay.refuse("a message was sent on {s} after its socket closed: {s}", .{ url, shown });
        const step = played.current() orelse return replay.refuse("a message was sent on {s} where the recording has no more steps: {s}", .{ url, shown });
        const expected = step.client orelse return replay.refuse("a message was sent on {s} where the recording has none from the client: {s}", .{ url, shown });
        if (!try matches(replay.arena, expected, message)) {
            return replay.refuse("step {d} of {s}: {s} was sent where {s} was recorded", .{ played.step + 1, url, shown, try json.encode(replay.arena, expected) });
        }
        played.step += 1;
        try played.play();
    }

    fn receive(context: *anyopaque, arena: Allocator, wait_ms: ?u64) (websocket.Error || Allocator.Error)!websocket.Received {
        const played: *Played = @ptrCast(@alignCast(context));
        if (played.closed) return .closed;
        if (played.taken == played.given.items.len) {
            if (played.peer_closed) return .closed;
            return played.waitOut(wait_ms);
        }
        const message = played.given.items[played.taken];
        played.taken += 1;
        if (base64Of(message)) |kept| {
            const decoder = std.base64.standard.Decoder;
            const bytes = try arena.alloc(u8, decoder.calcSizeForSlice(kept) catch return error.Transport);
            decoder.decode(bytes, kept) catch return error.Transport;
            return .{ .message = .{ .binary = bytes } };
        }
        return .{ .message = .{ .text = try json.encode(arena, message) } };
    }

    /// Nothing comes until the client sends: the wait runs out on the test's clock; one without end never would.
    fn waitOut(played: *Played, wait_ms: ?u64) (websocket.Error || Allocator.Error)!websocket.Received {
        const ms = wait_ms orelse return played.replay.refuse("a receive on {s} waits for ever, as nothing comes until the client sends", .{played.recorded.url});
        if (played.replay.clock_ms) |clock| clock.* += @intCast(ms);
        return .quiet;
    }

    fn close(context: *anyopaque) void {
        const played: *Played = @ptrCast(@alignCast(context));
        played.closed = true;
    }

    /// What it holds is the replay's.
    fn deinit(_: *anyopaque) void {}
};

/// Whether `message` is the one recorded: bytes as the base64 kept, text as the JSON recorded.
fn matches(arena: Allocator, recorded: std.json.Value, message: websocket.Message) Allocator.Error!bool {
    switch (message) {
        .binary => |bytes| {
            const kept = base64Of(recorded) orelse return false;
            const encoder = std.base64.standard.Encoder;
            const encoded = try arena.alloc(u8, encoder.calcSize(bytes.len));
            return std.mem.eql(u8, encoder.encode(encoded, bytes), kept);
        },
        .text => |text| {
            const value = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return false;
            return json.equal(value, recorded);
        },
    }
}

/// The base64 of a message recorded as bytes, `{"base64": ...}` and nothing else; null for a JSON message.
fn base64Of(recorded: std.json.Value) ?[]const u8 {
    if (recorded != .object or recorded.object.count() != 1) return null;
    const kept = recorded.object.get("base64") orelse return null;
    return if (kept == .string) kept.string else null;
}

test "a socket as recorded plays its steps: the peer's messages up to the client's next, then its close" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const recorded = try json.decode([]const RecordedSocket, a,
        \\[{"url":"wss://api.example/listen?model=m","headers":{"authorization":"Token t"},"steps":[
        \\  {"server":{"type":"ready"}},{"client":{"base64":"AAEC"}},{"client":{"b":[1],"a":true}},
        \\  {"server":{"base64":"AwQ="}},{"close":"server"}]}]
    );
    var clock_ms: i64 = 0;
    var replay: SocketReplay = .init(a, recorded);
    replay.clock_ms = &clock_ms;
    const socket = try replay.connector().connect(.{ .url = "wss://api.example/listen?model=m", .headers = &.{.{ .name = "Authorization", .value = "Token t" }} });
    try std.testing.expectEqualStrings("{\"type\":\"ready\"}", (try socket.receive(a, 1000)).message.text);
    try std.testing.expectEqual(.quiet, std.meta.activeTag(try socket.receive(a, 1000)));
    try std.testing.expectEqual(@as(i64, 1000), clock_ms);
    try socket.send(.{ .binary = &.{ 0, 1, 2 } });
    try socket.send(.{ .text = "{\"a\":true,\"b\":[1.0]}" });
    try std.testing.expectEqualSlices(u8, &.{ 3, 4 }, (try socket.receive(a, null)).message.binary);
    try std.testing.expectEqual(.closed, std.meta.activeTag(try socket.receive(a, null)));
    socket.deinit();
    try std.testing.expectEqual(@as(usize, 0), replay.unplayed());
}

test "a socket or a message the recording does not expect is refused, saying why" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const recorded = try json.decode([]const RecordedSocket, a,
        \\[{"url":"wss://api.example/a","steps":[{"client":{"type":"finalize"}}]}]
    );
    var replay: SocketReplay = .init(a, recorded);
    try std.testing.expectError(error.Transport, replay.connector().connect(.{ .url = "wss://api.example/b" }));
    try std.testing.expectEqualStrings("socket 1: wss://api.example/b was opened where wss://api.example/a was recorded", replay.mismatch.?);
    replay = .init(a, recorded);
    const socket = try replay.connector().connect(.{ .url = "wss://api.example/a" });
    try std.testing.expectError(error.Transport, socket.send(.{ .text = "{\"type\":\"close\"}" }));
    try std.testing.expectEqualStrings("step 1 of wss://api.example/a: {\"type\":\"close\"} was sent where {\"type\":\"finalize\"} was recorded", replay.mismatch.?);
    try std.testing.expectEqual(@as(usize, 1), replay.unplayed());
}
