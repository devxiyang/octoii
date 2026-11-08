//! A transport within one process, for tests and for servers that run in the client's own: the client's end, and a
//! server that takes each message as it is sent and answers through its sink. Messages cross as JSON text, as over a
//! real channel, and are routed as a line channel's are.
const std = @import("std");
const Allocator = std.mem.Allocator;
const jsonrpc = @import("jsonrpc.zig");
const protocol = @import("protocol.zig");
const transport_ = @import("transport.zig");
const Host = transport_.Host;
const Incoming = transport_.Incoming;
const router_ = @import("router.zig");
const failure_ = @import("failure.zig");
const Slot = failure_.Slot;
const Error = failure_.Error;

/// The server's end: what takes each message the client sends.
pub const Server = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Takes `message`, JSON text, answering through `sink` now or later.
        handle: *const fn (context: *anyopaque, sink: Sink, message: []const u8) void,
        /// The channel closed from the client's side.
        closed: *const fn (context: *anyopaque) void,
    };
};

/// Where the server sends what it sends the client.
pub const Sink = struct {
    pair: *Pair,

    /// Sends `message`, JSON text, to the client.
    pub fn send(sink: Sink, message: []const u8) void {
        sink.pair.router.arrive(message) catch {};
    }

    /// Closes the channel from the server's side, as a process that exits.
    pub fn close(sink: Sink) void {
        sink.pair.router.shut("the server closed the in-process channel");
    }
};

pub const Pair = struct {
    gpa: Allocator,
    router: router_.Router,
    server: Server,

    pub fn init(gpa: Allocator, host: *const Host, server: Server) Allocator.Error!*Pair {
        const pair = try gpa.create(Pair);
        pair.* = .{ .gpa = gpa, .router = .init(gpa, host), .server = server };
        return pair;
    }

    pub fn deinit(pair: *Pair) void {
        pair.router.deinit();
        pair.gpa.destroy(pair);
    }

    pub fn transport(pair: *Pair) transport_.Transport {
        return .{ .context = pair, .vtable = &.{ .request = request, .send = send, .receive = receive, .negotiated = negotiated, .isClosed = isClosed, .close = close } };
    }

    fn of(context: *anyopaque) *Pair {
        return @ptrCast(@alignCast(context));
    }

    /// Hands `message` to the server, which answers through the pair.
    fn deliver(pair: *Pair, slot: *Slot, message: jsonrpc.Message) Error!void {
        if (pair.router.isClosed()) return slot.fail(.{ .connection_lost = "The in-process channel is closed" });
        pair.server.vtable.handle(pair.server.context, .{ .pair = pair }, try message.encode(slot.arena));
    }

    fn request(context: *anyopaque, slot: *Slot, message: jsonrpc.Request, _: transport_.Sending) Error!transport_.Exchange {
        const pair = of(context);
        const exchange = try pair.gpa.create(Exchange);
        errdefer pair.gpa.destroy(exchange);
        exchange.* = .{ .pair = pair, .mailbox = try pair.router.open(message.id) };
        pair.deliver(slot, .{ .request = message }) catch |err| {
            Exchange.closeOf(exchange);
            return err;
        };
        return .{ .context = exchange, .vtable = &.{ .next = Exchange.next, .cancel = Exchange.cancel, .close = Exchange.closeOf } };
    }

    fn send(context: *anyopaque, slot: *Slot, message: jsonrpc.Message) Error!void {
        return of(context).deliver(slot, message);
    }

    fn receive(context: *anyopaque, slot: *Slot, wait_ms: ?u64) Error!Incoming {
        return of(context).router.receive(slot, wait_ms);
    }

    fn negotiated(_: *anyopaque, _: []const u8, _: protocol.Era) void {}

    fn isClosed(context: *anyopaque) bool {
        return of(context).router.isClosed();
    }

    fn close(context: *anyopaque) void {
        const pair = of(context);
        pair.router.shut(null);
        pair.server.vtable.closed(pair.server.context);
    }
};

const Exchange = struct {
    pair: *Pair,
    mailbox: *router_.Mailbox,

    fn of(context: *anyopaque) *Exchange {
        return @ptrCast(@alignCast(context));
    }

    fn next(context: *anyopaque, slot: *Slot, wait_ms: ?u64) Error!Incoming {
        const exchange = Exchange.of(context);
        return exchange.pair.router.next(exchange.mailbox, slot, wait_ms);
    }

    /// Cancels with `notifications/cancelled`, as a channel without a stream per request does.
    fn cancel(context: *anyopaque, reason: []const u8) void {
        const exchange = Exchange.of(context);
        var scratch: std.heap.ArenaAllocator = .init(exchange.pair.gpa);
        defer scratch.deinit();
        var slot: Slot = .{ .arena = scratch.allocator() };
        if (transport_.cancelledNotification(scratch.allocator(), exchange.mailbox.id, reason)) |cancelled| {
            exchange.pair.deliver(&slot, cancelled) catch {};
        } else |_| {}
        closeOf(context);
    }

    fn closeOf(context: *anyopaque) void {
        const exchange = Exchange.of(context);
        exchange.pair.router.close(exchange.mailbox);
        exchange.pair.gpa.destroy(exchange);
    }
};
