//! A socket a test plays the provider of by hand: the address and headers it opened with, what the client sent, the
//! provider's messages the test gives, and its close. A receive with nothing to give waits out its wait on the test's
//! clock.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const websocket = foundation.websocket;

pub const Scripted = struct {
    arena: Allocator,
    /// The test's clock, which a wait that nothing ends moves on.
    clock_ms: *i64,
    /// The address it opened with; none until it opens.
    url: ?[]const u8 = null,
    headers: []const foundation.http.Header = &.{},
    /// The client's messages, text or bytes as base64, in order.
    sent: std.ArrayList([]const u8) = .empty,
    given: std.ArrayList([]const u8) = .empty,
    taken: usize = 0,
    /// Whether the provider ended it, and whether the client closed it.
    ended: bool = false,
    closed: bool = false,

    pub fn init(arena: Allocator, clock_ms: *i64) Scripted {
        return .{ .arena = arena, .clock_ms = clock_ms };
    }

    pub fn connector(scripted: *Scripted) websocket.Connector {
        return .{ .context = scripted, .vtable = &.{ .connect = connect } };
    }

    /// Gives the client a message from the provider.
    pub fn give(scripted: *Scripted, message: []const u8) !void {
        try scripted.given.append(scripted.arena, try scripted.arena.dupe(u8, message));
    }

    /// Closes it, as the provider.
    pub fn end(scripted: *Scripted) void {
        scripted.ended = true;
    }

    fn of(context: *anyopaque) *Scripted {
        return @ptrCast(@alignCast(context));
    }

    fn connect(context: *anyopaque, opening: websocket.Opening) (websocket.Error || Allocator.Error)!websocket.Socket {
        const scripted = of(context);
        if (scripted.url != null) return error.Transport;
        scripted.url = try scripted.arena.dupe(u8, opening.url);
        scripted.headers = try scripted.arena.dupe(foundation.http.Header, opening.headers);
        return .{ .context = scripted, .vtable = &.{ .send = send, .receive = receive, .close = close, .deinit = deinit } };
    }

    fn send(context: *anyopaque, message: websocket.Message) websocket.Error!void {
        const scripted = of(context);
        if (scripted.closed) return error.Transport;
        const kept = switch (message) {
            .text => |text| scripted.arena.dupe(u8, text),
            .binary => |bytes| encoded: {
                const encoder = std.base64.standard.Encoder;
                const out = scripted.arena.alloc(u8, encoder.calcSize(bytes.len)) catch return error.Transport;
                break :encoded encoder.encode(out, bytes);
            },
        } catch return error.Transport;
        scripted.sent.append(scripted.arena, kept) catch return error.Transport;
    }

    fn receive(context: *anyopaque, arena: Allocator, wait_ms: ?u64) (websocket.Error || Allocator.Error)!websocket.Received {
        const scripted = of(context);
        if (scripted.closed) return .closed;
        if (scripted.taken < scripted.given.items.len) {
            defer scripted.taken += 1;
            return .{ .message = .{ .text = try arena.dupe(u8, scripted.given.items[scripted.taken]) } };
        }
        if (scripted.ended) return .closed;
        // Nothing comes until the test gives it: a wait without end would never end.
        const ms = wait_ms orelse return error.Transport;
        scripted.clock_ms.* += @intCast(ms);
        return .quiet;
    }

    fn close(context: *anyopaque) void {
        of(context).closed = true;
    }

    fn deinit(_: *anyopaque) void {}
};
