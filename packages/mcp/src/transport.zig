//! How a client reaches a server: the interface every transport implements, and the host it runs on. A request opens
//! an exchange — what comes back for it, read as it comes, ending with its answer — so that each request is waited for
//! by its own caller; what the server sends apart from any request is received apart. A transport never reconnects by
//! itself: whether and when to connect again is its caller's choice.
const std = @import("std");
const foundation = @import("foundation");
const Header = foundation.http.Header;
const jsonrpc = @import("jsonrpc.zig");
const protocol = @import("protocol.zig");
const failure_ = @import("failure.zig");
const Slot = failure_.Slot;
const Error = failure_.Error;

/// What a client takes of its host: the io, and the clock, waits and randomness, the io's unless the host gives its own.
pub const Host = struct {
    io: std.Io,
    clock: ?foundation.time.Clock = null,
    sleeper: ?foundation.time.Sleeper = null,
    random: ?std.Random = null,

    pub fn nowMs(host: *const Host) i64 {
        return foundation.time.nowMs(host.io, host.clock);
    }

    pub fn sleep(host: *const Host, ms: u64) error{Canceled}!void {
        return foundation.time.sleep(host.io, host.sleeper, ms);
    }

    pub fn randomBytes(host: *const Host, buffer: []u8) void {
        if (host.random) |random| return random.bytes(buffer);
        host.io.random(buffer);
    }
};

/// What a wait for a message came to.
pub const Incoming = union(enum) {
    /// A message, and whether the transport relates it to the request it was read for, as a request's own stream does.
    message: struct { message: jsonrpc.Message, related: bool = true },
    /// Nothing came within the wait.
    quiet,
    /// The request's stream ended before its answer, and could not be resumed.
    lost,
    /// The transport closed; why, where its server went away and says.
    closed: ?[]const u8,
};

/// What comes back for one request. On a transport that cannot tell which request a server's own request is for, as
/// stdio cannot, each exchange also gives those, unrelated, for whoever waits to answer.
pub const Exchange = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The next message, in the slot's arena, waiting at most `wait_ms`; none, until one comes.
        next: *const fn (context: *anyopaque, slot: *Slot, wait_ms: ?u64) Error!Incoming,
        /// Cancels the request as the transport does — by closing its stream, or with `notifications/cancelled` — and
        /// lets the exchange go.
        cancel: *const fn (context: *anyopaque, reason: []const u8) void,
        /// Lets the exchange go, its answer read.
        close: *const fn (context: *anyopaque) void,
    };

    pub fn next(exchange: Exchange, slot: *Slot, wait_ms: ?u64) Error!Incoming {
        return exchange.vtable.next(exchange.context, slot, wait_ms);
    }

    pub fn cancel(exchange: Exchange, reason: []const u8) void {
        exchange.vtable.cancel(exchange.context, reason);
    }

    pub fn close(exchange: Exchange) void {
        exchange.vtable.close(exchange.context);
    }
};

/// How a request is sent: the headers an HTTP transport adds, such as a tool's `Mcp-Param-*`, and how long it may
/// wait between two of its messages, which a transport that must say so up front, as HTTP's reads do, takes; none,
/// without end.
pub const Sending = struct {
    headers: []const Header = &.{},
    idle_ms: ?u64 = null,
};

/// A channel of JSON-RPC messages to one server.
pub const Transport = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Sends `request` as `sending` says, and opens its exchange; fails where the server refused it outright, as
        /// HTTP does with a status.
        request: *const fn (context: *anyopaque, slot: *Slot, request: jsonrpc.Request, sending: Sending) Error!Exchange,
        /// Sends a notification, or the answer to a server's request.
        send: *const fn (context: *anyopaque, slot: *Slot, message: jsonrpc.Message) Error!void,
        /// The next message the server sent apart from any request — a log message, a list's change, a session's own
        /// request — waiting at most `wait_ms`.
        receive: *const fn (context: *anyopaque, slot: *Slot, wait_ms: ?u64) Error!Incoming,
        /// The version the client settled on and its era, which decide how the transport works from then on.
        negotiated: *const fn (context: *anyopaque, version: []const u8, era: protocol.Era) void,
        /// Whether the channel is closed — its server went away, its session ended, or it was closed — as a socket's
        /// end is known once its peer closes it, whether or not anything read it.
        isClosed: *const fn (context: *anyopaque) bool,
        /// Closes the channel — ends a session, stops a process — and lets it go.
        close: *const fn (context: *anyopaque) void,
    };

    pub fn request(transport: Transport, slot: *Slot, message: jsonrpc.Request, sending: Sending) Error!Exchange {
        return transport.vtable.request(transport.context, slot, message, sending);
    }

    pub fn send(transport: Transport, slot: *Slot, message: jsonrpc.Message) Error!void {
        return transport.vtable.send(transport.context, slot, message);
    }

    pub fn receive(transport: Transport, slot: *Slot, wait_ms: ?u64) Error!Incoming {
        return transport.vtable.receive(transport.context, slot, wait_ms);
    }

    pub fn negotiated(transport: Transport, version: []const u8, era: protocol.Era) void {
        transport.vtable.negotiated(transport.context, version, era);
    }

    pub fn isClosed(transport: Transport) bool {
        return transport.vtable.isClosed(transport.context);
    }

    pub fn close(transport: Transport) void {
        transport.vtable.close(transport.context);
    }
};

/// The `notifications/cancelled` a transport without a stream per request sends to cancel one.
pub fn cancelledNotification(arena: std.mem.Allocator, id: jsonrpc.Id, reason: []const u8) std.mem.Allocator.Error!jsonrpc.Message {
    var params: std.json.ObjectMap = .empty;
    try params.put(arena, "requestId", switch (id) {
        .number => |number| .{ .integer = number },
        .string => |text| .{ .string = text },
    });
    try params.put(arena, "reason", .{ .string = reason });
    return .{ .notification = .{ .method = "notifications/cancelled", .params = .{ .object = params } } };
}

/// The request a message is for, on a channel that carries every request's messages: a response's; a progress
/// notification's, whose token is its request's id; a subscription's notification, by the id its metadata names; and
/// the cancellation of a request the client made, as a server ends a subscription with on such a channel.
pub fn relatedId(message: jsonrpc.Message) ?jsonrpc.Id {
    const notification = switch (message) {
        .result, .failure => return message.answers(),
        .request => return null,
        .notification => |given| given,
    };
    const params = notification.params orelse return null;
    if (params != .object) return null;
    if (std.mem.eql(u8, notification.method, "notifications/progress")) return jsonrpc.Id.of(params.object.get("progressToken") orelse return null);
    if (std.mem.eql(u8, notification.method, "notifications/cancelled")) return jsonrpc.Id.of(params.object.get("requestId") orelse return null);
    const meta = params.object.get("_meta") orelse return null;
    if (meta != .object) return null;
    return jsonrpc.Id.of(meta.object.get(protocol.meta.subscription_id) orelse return null);
}
