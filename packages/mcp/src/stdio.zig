//! The stdio transport: the server a process its host runs — a command on a machine — talked to as JSON-RPC a line, on
//! foundation's line peer, each request's messages routed to it by MCP's own rule. The process's end closes the
//! transport, saying how where nobody asked it to. Closing the transport stops the server — asks it to end by the end of
//! its input, as MCP's shutdown on stdio begins — and lets it go to its host, which ends what still runs of it as a
//! server is ended, nobody waiting.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const jsonrpc = foundation.jsonrpc;
const Lines = jsonrpc.Lines;
const protocol = @import("protocol.zig");
const transport_ = @import("transport.zig");
const Host = transport_.Host;
const Incoming = transport_.Incoming;
const failure_ = @import("failure.zig");
const Slot = failure_.Slot;
const Error = failure_.Error;

pub const Stdio = struct {
    gpa: Allocator,
    lines: *Lines,

    /// Talks to the server `process` runs, which the transport owns from here; `connection_lost` where the host's io
    /// cannot read it.
    pub fn start(gpa: Allocator, host: *const Host, slot: *Slot, process: Lines.Process) Error!*Stdio {
        const lines = Lines.start(gpa, .{ .io = host.io, .sleeper = host.sleeper }, process, transport_.relatedId) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unconcurrent => return slot.fail(.{ .connection_lost = "The host's io runs nothing concurrently, which a server over stdio needs" }),
        };
        errdefer lines.close();
        const stdio = try gpa.create(Stdio);
        errdefer gpa.destroy(stdio);
        stdio.* = .{ .gpa = gpa, .lines = lines };
        return stdio;
    }

    pub fn transport(stdio: *Stdio) transport_.Transport {
        return .{ .context = stdio, .vtable = &.{ .request = request, .send = send, .receive = receive, .negotiated = negotiated, .isClosed = isClosed, .close = close } };
    }

    fn of(context: *anyopaque) *Stdio {
        return @ptrCast(@alignCast(context));
    }

    fn request(context: *anyopaque, slot: *Slot, message: jsonrpc.Request, _: transport_.Sending) Error!transport_.Exchange {
        const stdio = of(context);
        const exchange = switch (try stdio.lines.request(slot.arena, message)) {
            .exchange => |sent| sent,
            .unwritten => |why| return slot.fail(.{ .connection_lost = why }),
        };
        errdefer exchange.close();
        const held = try stdio.gpa.create(Exchange);
        errdefer stdio.gpa.destroy(held);
        held.* = .{ .gpa = stdio.gpa, .exchange = exchange };
        return .{ .context = held, .vtable = &.{ .next = Exchange.next, .cancel = Exchange.cancel, .close = Exchange.closeOf } };
    }

    fn send(context: *anyopaque, slot: *Slot, message: jsonrpc.Message) Error!void {
        const why = try of(context).lines.write(slot.arena, message) orelse return;
        return slot.fail(.{ .connection_lost = why });
    }

    fn receive(context: *anyopaque, slot: *Slot, wait_ms: ?u64) Error!Incoming {
        return transport_.incomingOf(slot, of(context).lines.receive(slot.arena, wait_ms));
    }

    fn negotiated(_: *anyopaque, _: []const u8, _: protocol.Era) void {}

    fn isClosed(context: *anyopaque) bool {
        return of(context).lines.isClosed();
    }

    /// Stops the server and lets the transport go: what still runs of the server its host ends.
    fn close(context: *anyopaque) void {
        const stdio = of(context);
        stdio.lines.close();
        stdio.gpa.destroy(stdio);
    }
};

/// One request's exchange, held where MCP's transport keeps it.
const Exchange = struct {
    gpa: Allocator,
    exchange: Lines.Exchange,

    fn of(context: *anyopaque) *Exchange {
        return @ptrCast(@alignCast(context));
    }

    fn next(context: *anyopaque, slot: *Slot, wait_ms: ?u64) Error!Incoming {
        return transport_.incomingOf(slot, Exchange.of(context).exchange.next(slot.arena, wait_ms));
    }

    /// Cancels with `notifications/cancelled`.
    fn cancel(context: *anyopaque, reason: []const u8) void {
        const held = Exchange.of(context);
        held.exchange.cancel(reason);
        held.gpa.destroy(held);
    }

    fn closeOf(context: *anyopaque) void {
        const held = Exchange.of(context);
        held.exchange.close();
        held.gpa.destroy(held);
    }
};
