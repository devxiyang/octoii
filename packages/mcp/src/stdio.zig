//! The stdio transport: the server a process its host runs — a command on a machine — talked to a JSON-RPC message a
//! line: each written to its input whole, each line it writes routed to the request it is for, the rest apart. A task
//! on the host's io reads the process until it ends, and its end closes the transport, saying how where nobody asked it
//! to. Closing the transport stops the server — asks it to end by the end of its input, as MCP's shutdown on stdio
//! begins — and lets it go to its host, which ends what still runs of it as a server is ended, nobody waiting.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const jsonrpc = @import("jsonrpc.zig");
const protocol = @import("protocol.zig");
const transport_ = @import("transport.zig");
const Host = transport_.Host;
const Incoming = transport_.Incoming;
const router_ = @import("router.zig");
const failure_ = @import("failure.zig");
const Slot = failure_.Slot;
const Error = failure_.Error;

/// A server's process, as the transport talks to it.
pub const Process = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Writes `line`, its newline with it, to the process's input, whole: null, or why it could not, in `arena`.
        write: *const fn (context: *anyopaque, arena: Allocator, line: []const u8) Allocator.Error!?[]const u8,
        /// Waits for what the process writes next: the whole lines it wrote, or how it ended, in `arena` — at once,
        /// once it is stopped.
        read: *const fn (context: *anyopaque, arena: Allocator) Allocator.Error!Read,
        /// Stops the process: asks it to end, as a server is asked, by the end of its input; `read`, waiting or to
        /// come, tells of its end at once.
        stop: *const fn (context: *anyopaque) void,
        /// Lets the process go once nothing reads it: its host ends what still runs of it as a server is ended, nobody
        /// waiting.
        release: *const fn (context: *anyopaque) void,
    };

    /// What a read came to: the lines the process wrote, each without its newline; or, where it ended, how.
    pub const Read = union(enum) { lines: []const []const u8, ended: []const u8 };
};

pub const Stdio = struct {
    gpa: Allocator,
    host: *const Host,
    router: router_.Router,
    process: Process,
    /// Set as the transport closes: the server's end, from then, is asked for.
    closing: std.atomic.Value(bool) = .init(false),
    reading: ?Io.Future(void) = null,

    /// Talks to the server `process` runs, which the transport owns from here; `connection_lost` where the host's io
    /// cannot read it.
    pub fn start(gpa: Allocator, host: *const Host, slot: *Slot, process: Process) Error!*Stdio {
        const stdio = gpa.create(Stdio) catch |err| {
            discard(process);
            return err;
        };
        errdefer gpa.destroy(stdio);
        stdio.* = .{ .gpa = gpa, .host = host, .router = .init(gpa, host), .process = process };
        stdio.reading = host.io.concurrent(readAll, .{stdio}) catch {
            discard(process);
            stdio.router.deinit();
            gpa.destroy(stdio);
            return slot.fail(.{ .connection_lost = "The host's io runs nothing concurrently, which a server over stdio needs" });
        };
        return stdio;
    }

    pub fn transport(stdio: *Stdio) transport_.Transport {
        return .{ .context = stdio, .vtable = &.{ .request = request, .send = send, .receive = receive, .negotiated = negotiated, .isClosed = isClosed, .close = close } };
    }

    fn of(context: *anyopaque) *Stdio {
        return @ptrCast(@alignCast(context));
    }

    /// Routes each line the server writes, until it ends: its end closes the channel, saying how where it was not
    /// asked to end.
    fn readAll(stdio: *Stdio) void {
        var arena_allocator: std.heap.ArenaAllocator = .init(stdio.gpa);
        defer arena_allocator.deinit();
        while (true) {
            _ = arena_allocator.reset(.retain_capacity);
            const read = stdio.process.vtable.read(stdio.process.context, arena_allocator.allocator()) catch {
                stdio.router.shut("the MCP server's process could not be read");
                return;
            };
            switch (read) {
                .lines => |lines| for (lines) |line| {
                    const text = std.mem.trim(u8, line, " \t\r");
                    if (text.len > 0) stdio.router.arrive(text) catch {};
                },
                .ended => |how| return stdio.router.shut(if (stdio.closing.load(.acquire)) null else how),
            }
        }
    }

    /// Writes `message` as a line to the server's input.
    fn write(stdio: *Stdio, slot: *Slot, message: jsonrpc.Message) Error!void {
        if (stdio.router.isClosed()) return slot.fail(.{ .connection_lost = "The MCP server's process is not running" });
        const line = try std.mem.concat(slot.arena, u8, &.{ try message.encode(slot.arena), "\n" });
        if (try stdio.process.vtable.write(stdio.process.context, slot.arena, line)) |why| return slot.fail(.{ .connection_lost = why });
    }

    fn request(context: *anyopaque, slot: *Slot, message: jsonrpc.Request, _: transport_.Sending) Error!transport_.Exchange {
        const stdio = of(context);
        const exchange = try stdio.gpa.create(Exchange);
        errdefer stdio.gpa.destroy(exchange);
        exchange.* = .{ .stdio = stdio, .mailbox = try stdio.router.open(message.id) };
        stdio.write(slot, .{ .request = message }) catch |err| {
            Exchange.closeOf(exchange);
            return err;
        };
        return .{ .context = exchange, .vtable = &.{ .next = Exchange.next, .cancel = Exchange.cancel, .close = Exchange.closeOf } };
    }

    fn send(context: *anyopaque, slot: *Slot, message: jsonrpc.Message) Error!void {
        return of(context).write(slot, message);
    }

    fn receive(context: *anyopaque, slot: *Slot, wait_ms: ?u64) Error!Incoming {
        return of(context).router.receive(slot, wait_ms);
    }

    fn negotiated(_: *anyopaque, _: []const u8, _: protocol.Era) void {}

    fn isClosed(context: *anyopaque) bool {
        return of(context).router.isClosed();
    }

    /// Stops the server, waits for its reader, which stopping ends at once, and lets the transport go: what still runs
    /// of the server its host ends.
    fn close(context: *anyopaque) void {
        const stdio = of(context);
        stdio.closing.store(true, .release);
        stdio.process.vtable.stop(stdio.process.context);
        if (stdio.reading) |*reading| reading.await(stdio.host.io);
        stdio.reading = null;
        stdio.let();
    }

    /// Lets go of the process and all else the transport holds, nothing reading it.
    fn let(stdio: *Stdio) void {
        stdio.process.vtable.release(stdio.process.context);
        stdio.router.shut(null);
        stdio.router.deinit();
        stdio.gpa.destroy(stdio);
    }
};

/// Stops `process` and lets it go, where no transport takes it.
fn discard(process: Process) void {
    process.vtable.stop(process.context);
    process.vtable.release(process.context);
}

const Exchange = struct {
    stdio: *Stdio,
    mailbox: *router_.Mailbox,

    fn of(context: *anyopaque) *Exchange {
        return @ptrCast(@alignCast(context));
    }

    fn next(context: *anyopaque, slot: *Slot, wait_ms: ?u64) Error!Incoming {
        const exchange = Exchange.of(context);
        return exchange.stdio.router.next(exchange.mailbox, slot, wait_ms);
    }

    /// Cancels with `notifications/cancelled`.
    fn cancel(context: *anyopaque, reason: []const u8) void {
        const exchange = Exchange.of(context);
        var scratch_arena: std.heap.ArenaAllocator = .init(exchange.stdio.gpa);
        defer scratch_arena.deinit();
        var slot: Slot = .{ .arena = scratch_arena.allocator() };
        if (transport_.cancelledNotification(scratch_arena.allocator(), exchange.mailbox.id, reason)) |cancelled| {
            exchange.stdio.write(&slot, cancelled) catch {};
        } else |_| {}
        closeOf(context);
    }

    fn closeOf(context: *anyopaque) void {
        const exchange = Exchange.of(context);
        exchange.stdio.router.close(exchange.mailbox);
        exchange.stdio.gpa.destroy(exchange);
    }
};
