//! JSON-RPC to a process, a message a line: each written to its input whole, each line it writes routed to the request
//! it is for, by the protocol's own rule, the rest apart. A task on the io reads the process until it ends, and its end
//! closes the channel, saying how where nobody asked it to. Closing stops the process — asks it to end by the end of its
//! input — and lets it go to its host, which ends what still runs of it, nobody waiting.
const Lines = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const jsonrpc = @import("../jsonrpc.zig");
const Router = @import("Router.zig");

/// A process, as the peer talks to it.
pub const Process = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Takes `line`, its newline with it, for the process's input, whole and in order, never waiting for the
        /// process to read it: null, or why it takes nothing, in `arena`.
        write: *const fn (context: *anyopaque, arena: Allocator, line: []const u8) Allocator.Error!?[]const u8,
        /// Waits for what the process writes next: the whole lines it wrote, or how it ended, in `arena` — at once,
        /// once it is stopped.
        read: *const fn (context: *anyopaque, arena: Allocator) Allocator.Error!Read,
        /// Stops the process: asks it to end by the end of its input; `read`, waiting or to come, tells of its end at
        /// once.
        stop: *const fn (context: *anyopaque) void,
        /// Lets the process go once nothing reads it: its host ends what still runs of it, nobody waiting.
        release: *const fn (context: *anyopaque) void,
    };

    /// What a read came to: the lines the process wrote, each without its newline; or, where it ended, how.
    pub const Read = union(enum) { lines: []const []const u8, ended: []const u8 };
};

gpa: Allocator,
router: Router,
process: Process,
/// Set as the peer closes: the process's end, from then, is asked for.
closing: std.atomic.Value(bool) = .init(false),
reading: ?Io.Future(void) = null,

/// Talks to `process`, which the peer owns from here, its messages told apart by `relate`; `error.Unconcurrent` where
/// the io runs nothing concurrently, which a peer that reads a process needs — the process let go either way.
pub fn start(gpa: Allocator, waits: Router.Waits, process: Process, relate: jsonrpc.Relate) error{ OutOfMemory, Unconcurrent }!*Lines {
    errdefer discard(process);
    const lines = try gpa.create(Lines);
    errdefer gpa.destroy(lines);
    lines.* = .{ .gpa = gpa, .router = .init(gpa, waits, relate), .process = process };
    errdefer lines.router.deinit();
    lines.reading = waits.io.concurrent(readAll, .{lines}) catch return error.Unconcurrent;
    return lines;
}

/// Routes each line the process writes, until it ends: its end closes the channel, saying how where it was not asked
/// to end.
fn readAll(lines: *Lines) void {
    var arena_allocator: std.heap.ArenaAllocator = .init(lines.gpa);
    defer arena_allocator.deinit();
    while (true) {
        _ = arena_allocator.reset(.retain_capacity);
        const read = lines.process.vtable.read(lines.process.context, arena_allocator.allocator()) catch {
            lines.router.shut("the process could not be read");
            return;
        };
        switch (read) {
            .lines => |each| for (each) |line| {
                const text = std.mem.trim(u8, line, " \t\r");
                if (text.len > 0) lines.router.arrive(text) catch {};
            },
            .ended => |how| return lines.router.shut(if (lines.closing.load(.acquire)) null else how),
        }
    }
}

/// Writes `message` as a line to the process's input: null, or why it could not, in `arena`.
pub fn write(lines: *Lines, arena: Allocator, message: jsonrpc.Message) Allocator.Error!?[]const u8 {
    if (lines.router.isClosed()) return "the process is not running";
    const line = try std.mem.concat(arena, u8, &.{ try message.encode(arena), "\n" });
    return lines.process.vtable.write(lines.process.context, arena, line);
}

/// A request sent: its exchange; or why it could not be written.
pub const Sent = union(enum) { exchange: Exchange, unwritten: []const u8 };

/// Sends `request`, and opens its exchange.
pub fn request(lines: *Lines, arena: Allocator, message: jsonrpc.Request) Allocator.Error!Sent {
    const exchange: Exchange = .{ .lines = lines, .mailbox = try lines.router.open(message.id) };
    const why = lines.write(arena, .{ .request = message }) catch |err| {
        exchange.close();
        return err;
    } orelse return .{ .exchange = exchange };
    exchange.close();
    return .{ .unwritten = why };
}

/// The next message the process sent apart from any request, waiting at most `wait_ms`, in `arena`.
pub fn receive(lines: *Lines, arena: Allocator, wait_ms: ?u64) Router.Error!Router.Incoming {
    return lines.router.receive(arena, wait_ms);
}

/// Whether the channel is closed: the process ended, or the peer was closed.
pub fn isClosed(lines: *Lines) bool {
    return lines.router.isClosed();
}

/// Stops the process, waits for the reader, which stopping ends at once, and lets the peer go: what still runs of the
/// process its host ends.
pub fn close(lines: *Lines) void {
    lines.closing.store(true, .release);
    lines.process.vtable.stop(lines.process.context);
    if (lines.reading) |*reading| reading.await(lines.router.waits.io);
    lines.reading = null;
    lines.process.vtable.release(lines.process.context);
    lines.router.shut(null);
    lines.router.deinit();
    lines.gpa.destroy(lines);
}

/// Stops `process` and lets it go, where no peer takes it.
fn discard(process: Process) void {
    process.vtable.stop(process.context);
    process.vtable.release(process.context);
}

/// What comes back for one request, as the router gives it.
pub const Exchange = struct {
    lines: *Lines,
    mailbox: *Router.Mailbox,

    /// The next message for the request, or a request of the process's own, waiting at most `wait_ms`, in `arena`.
    pub fn next(exchange: Exchange, arena: Allocator, wait_ms: ?u64) Router.Error!Router.Incoming {
        return exchange.lines.router.next(exchange.mailbox, arena, wait_ms);
    }

    /// Cancels the request with `notifications/cancelled`, saying why, and lets the exchange go.
    pub fn cancel(exchange: Exchange, reason: []const u8) void {
        var scratch_arena: std.heap.ArenaAllocator = .init(exchange.lines.gpa);
        defer scratch_arena.deinit();
        const arena = scratch_arena.allocator();
        if (jsonrpc.cancelled(arena, exchange.mailbox.id, reason)) |message| {
            _ = exchange.lines.write(arena, message) catch null;
        } else |_| {}
        exchange.close();
    }

    /// Lets the exchange go, what came for it and was not read dropped.
    pub fn close(exchange: Exchange) void {
        exchange.lines.router.close(exchange.mailbox);
    }
};
