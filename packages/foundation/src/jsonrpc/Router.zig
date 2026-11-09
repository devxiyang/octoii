//! What a channel that carries every request's messages shares — a process's lines, an in-process pair: each message
//! the peer sends, as JSON text, goes to the mailbox of the request it is for, by the protocol's own rule, and wakes
//! who waits for that request alone; the rest apart, for who receives them, the peer's own requests given to whichever
//! exchange waits; the channel's end, with why, to all. A wait that nothing ends runs on the waits' sleeper where they
//! give one, as a test's moves its clock, else on the io.
const Router = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const jsonrpc = @import("../jsonrpc.zig");
const time = @import("../time.zig");

/// How a router waits: on the io, or on a sleeper that stands in for it, as a test's clock.
pub const Waits = struct { io: Io, sleeper: ?time.Sleeper = null };

/// What a wait for a message came to: a message — and whether it is the request's own, or a request of the peer's,
/// given to whichever exchange waits; none for the whole wait; or the channel's end, with why where the peer went away.
pub const Incoming = union(enum) {
    message: struct { message: jsonrpc.Message, related: bool = true },
    quiet,
    closed: ?[]const u8,
};

/// What a wait fails with: memory, or the task that waits cancelled.
pub const Error = error{ OutOfMemory, Canceled };

/// A message the peer sent, kept as its text until read.
const Kept = struct { text: []u8, is_request: bool };

/// The messages of one request, until it reads them, and what wakes it as one comes.
pub const Mailbox = struct { id: jsonrpc.Id, messages: std.ArrayList([]u8) = .empty, arrived: Io.Condition = .init };

/// How many messages apart from any request are kept for a reader; the oldest notification goes past that.
const unrelated_max = 1024;

gpa: Allocator,
waits: Waits,
/// What tells which request a message is for.
relate: jsonrpc.Relate,
lock: Io.Mutex = .init,
/// What wakes who receives what comes apart from any request.
apart: Io.Condition = .init,
mailboxes: std.ArrayList(*Mailbox) = .empty,
unrelated: std.ArrayList(Kept) = .empty,
closed: bool = false,
/// Why the channel closed, where its peer went away, for whoever waits.
reason: ?[]u8 = null,

pub fn init(gpa: Allocator, waits: Waits, relate: jsonrpc.Relate) Router {
    return .{ .gpa = gpa, .waits = waits, .relate = relate };
}

pub fn deinit(router: *Router) void {
    for (router.mailboxes.items) |mailbox| router.drop(mailbox);
    router.mailboxes.deinit(router.gpa);
    for (router.unrelated.items) |kept| router.gpa.free(kept.text);
    router.unrelated.deinit(router.gpa);
    if (router.reason) |reason| router.gpa.free(reason);
}

/// A mailbox for the request `id`, kept until it is closed.
pub fn open(router: *Router, id: jsonrpc.Id) Allocator.Error!*Mailbox {
    const mailbox = try router.gpa.create(Mailbox);
    errdefer router.gpa.destroy(mailbox);
    mailbox.* = .{ .id = switch (id) {
        .number => id,
        .string => |text| .{ .string = try router.gpa.dupe(u8, text) },
    } };
    router.lock.lockUncancelable(router.waits.io);
    defer router.lock.unlock(router.waits.io);
    try router.mailboxes.append(router.gpa, mailbox);
    return mailbox;
}

/// Closes a mailbox, what it holds dropped.
pub fn close(router: *Router, mailbox: *Mailbox) void {
    {
        router.lock.lockUncancelable(router.waits.io);
        defer router.lock.unlock(router.waits.io);
        for (router.mailboxes.items, 0..) |each, index| if (each == mailbox) {
            _ = router.mailboxes.swapRemove(index);
            break;
        };
    }
    router.drop(mailbox);
}

fn drop(router: *Router, mailbox: *Mailbox) void {
    for (mailbox.messages.items) |text| router.gpa.free(text);
    mailbox.messages.deinit(router.gpa);
    if (mailbox.id == .string) router.gpa.free(mailbox.id.string);
    router.gpa.destroy(mailbox);
}

/// Takes a message from the peer: to its request's mailbox where it has one, waking that request; one for a request
/// no longer waited for dropped, as what a request cancelled had on the way; the rest apart, waking who receives them
/// — and, for a request of the peer's own, every exchange; one that is no message dropped, as a peer must not send one.
pub fn arrive(router: *Router, text: []const u8) Allocator.Error!void {
    var scratch_arena: std.heap.ArenaAllocator = .init(router.gpa);
    defer scratch_arena.deinit();
    const message = jsonrpc.parseOne(scratch_arena.allocator(), text) catch return;
    const io = router.waits.io;
    router.lock.lockUncancelable(io);
    defer router.lock.unlock(io);
    if (router.closed) return;
    if (router.relate(message)) |id| {
        for (router.mailboxes.items) |mailbox| if (mailbox.id.eql(id)) {
            try mailbox.messages.ensureUnusedCapacity(router.gpa, 1);
            mailbox.messages.appendAssumeCapacity(try router.gpa.dupe(u8, text));
            return mailbox.arrived.signal(io);
        };
        return;
    }
    if (router.unrelated.items.len == unrelated_max) {
        for (router.unrelated.items, 0..) |kept, index| if (!kept.is_request) {
            router.gpa.free(router.unrelated.orderedRemove(index).text);
            break;
        };
    }
    try router.unrelated.ensureUnusedCapacity(router.gpa, 1);
    router.unrelated.appendAssumeCapacity(.{ .text = try router.gpa.dupe(u8, text), .is_request = message == .request });
    if (message == .request) router.wakeAll() else router.apart.broadcast(io);
}

/// Wakes every wait: each request's, and who receives what comes apart.
fn wakeAll(router: *Router) void {
    for (router.mailboxes.items) |mailbox| mailbox.arrived.broadcast(router.waits.io);
    router.apart.broadcast(router.waits.io);
}

/// Closes the channel; `reason`, where the peer went away, says why to whoever waits.
pub fn shut(router: *Router, reason: ?[]const u8) void {
    router.lock.lockUncancelable(router.waits.io);
    defer router.lock.unlock(router.waits.io);
    if (router.closed) return;
    router.closed = true;
    if (reason) |given| router.reason = router.gpa.dupe(u8, given) catch null;
    router.wakeAll();
}

pub fn isClosed(router: *Router) bool {
    router.lock.lockUncancelable(router.waits.io);
    defer router.lock.unlock(router.waits.io);
    return router.closed;
}

/// The channel's end, as an incoming, its reason in `arena`.
fn ended(router: *Router, arena: Allocator) Allocator.Error!Incoming {
    return .{ .closed = if (router.reason) |reason| try arena.dupe(u8, reason) else null };
}

/// The next message for `mailbox`'s request, or a request of the peer's own, waiting at most `wait_ms` for one — what
/// comes for other requests meanwhile not ending the wait — in `arena`.
pub fn next(router: *Router, mailbox: *Mailbox, arena: Allocator, wait_ms: ?u64) Error!Incoming {
    router.lock.lockUncancelable(router.waits.io);
    defer router.lock.unlock(router.waits.io);
    var wait = router.waitOf(wait_ms);
    while (true) {
        if (mailbox.messages.items.len > 0) {
            const text = mailbox.messages.orderedRemove(0);
            defer router.gpa.free(text);
            return .{ .message = .{ .message = try decoded(arena, text) } };
        }
        for (router.unrelated.items, 0..) |kept, index| if (kept.is_request) {
            const taken = router.unrelated.orderedRemove(index);
            defer router.gpa.free(taken.text);
            return .{ .message = .{ .message = try decoded(arena, taken.text), .related = false } };
        };
        if (router.closed) return router.ended(arena);
        if (!try router.waited(&mailbox.arrived, &wait)) return .quiet;
    }
}

/// The next message apart from any request, waiting at most `wait_ms` for one, in `arena`.
pub fn receive(router: *Router, arena: Allocator, wait_ms: ?u64) Error!Incoming {
    router.lock.lockUncancelable(router.waits.io);
    defer router.lock.unlock(router.waits.io);
    var wait = router.waitOf(wait_ms);
    while (true) {
        if (router.unrelated.items.len > 0) {
            const kept = router.unrelated.orderedRemove(0);
            defer router.gpa.free(kept.text);
            return .{ .message = .{ .message = try decoded(arena, kept.text), .related = false } };
        }
        if (router.closed) return router.ended(arena);
        if (!try router.waited(&router.apart, &wait)) return .quiet;
    }
}

/// One wait for a message: on the io, till its deadline, none waiting for ever; on the waits' sleeper, a sleep of it
/// whole, as a test's moves its clock on by it.
const Wait = struct { ms: ?u64, deadline: Io.Timeout, slept: bool = false };

fn waitOf(router: *Router, wait_ms: ?u64) Wait {
    const ms = wait_ms orelse return .{ .ms = null, .deadline = .none };
    const duration: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(@intCast(ms)), .clock = .awake } };
    return .{ .ms = ms, .deadline = duration.toDeadline(router.waits.io) };
}

/// Waits till `arrived` wakes it, the lock held but while it waits; false once the wait has passed.
fn waited(router: *Router, arrived: *Io.Condition, wait: *Wait) error{Canceled}!bool {
    const io = router.waits.io;
    if (router.waits.sleeper) |sleeper| {
        // Nothing comes but what a task sends, which a sleep lets run.
        if (wait.slept) return false;
        wait.slept = true;
        router.lock.unlock(io);
        defer router.lock.lockUncancelable(io);
        try sleeper.sleep(wait.ms orelse return error.Canceled);
        return true;
    }
    arrived.waitTimeout(io, &router.lock, wait.deadline) catch |err| switch (err) {
        error.Timeout => return false,
        error.Canceled => return error.Canceled,
    };
    return true;
}

fn decoded(arena: Allocator, text: []const u8) Allocator.Error!jsonrpc.Message {
    return jsonrpc.parseOne(arena, text) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // What the router keeps it read once already.
        error.NotJsonRpc => unreachable,
    };
}

/// The request a response answers, as the tests relate messages.
fn answered(message: jsonrpc.Message) ?jsonrpc.Id {
    return message.answers();
}

/// Answers the request 2, then, `gap_ms` on, the request 1, `gap_ms` apart; the request 1 never, where `answers_first`
/// is false.
fn answerLater(router: *Router, gap_ms: u64, answers_first: bool) void {
    const io = router.waits.io;
    io.sleep(.fromMilliseconds(@intCast(gap_ms)), .awake) catch return;
    router.arrive("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}") catch return;
    if (!answers_first) return;
    io.sleep(.fromMilliseconds(@intCast(gap_ms)), .awake) catch return;
    router.arrive("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}") catch return;
}

test "a request's wait lasts its whole time, what comes for another request meanwhile not ending it" {
    const io = std.testing.io;
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    for ([_]bool{ true, false }) |answers_first| {
        var router: Router = .init(std.testing.allocator, .{ .io = io }, answered);
        defer router.deinit();
        const first = try router.open(.{ .number = 1 });
        const second = try router.open(.{ .number = 2 });
        var answering = try io.concurrent(answerLater, .{ &router, 30, answers_first });
        const began = Io.Clock.awake.now(io).toMilliseconds();
        const incoming = try router.next(first, arena, if (answers_first) 5000 else 120);
        answering.await(io);
        const waited_ms = Io.Clock.awake.now(io).toMilliseconds() - began;
        if (answers_first) {
            try std.testing.expect(incoming.message.message.answers().?.eql(.{ .number = 1 }));
            try std.testing.expect(waited_ms >= 60);
        } else {
            try std.testing.expectEqual(.quiet, std.meta.activeTag(incoming));
            try std.testing.expect(waited_ms >= 120);
        }
        try std.testing.expect((try router.next(second, arena, 0)).message.message.answers().?.eql(.{ .number = 2 }));
        router.close(first);
        router.close(second);
    }
}
