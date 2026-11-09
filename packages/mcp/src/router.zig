//! What a transport whose one channel carries every request's messages shares — the in-process one, stdio: each
//! message the server sends, as JSON text, goes to the mailbox of the request it is for, and the rest apart, the
//! server's own requests given to whichever exchange waits; the channel's end, with why. A wait that nothing ends runs
//! on the host's sleep where it gives one, as a test's moves its clock, else on the io.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const jsonrpc = @import("jsonrpc.zig");
const transport_ = @import("transport.zig");
const Host = transport_.Host;
const Incoming = transport_.Incoming;
const failure_ = @import("failure.zig");
const Slot = failure_.Slot;
const Error = failure_.Error;

/// A message the server sent, kept as its text until read.
const Kept = struct { text: []u8, is_request: bool };

/// The messages of one request, until it reads them.
pub const Mailbox = struct { id: jsonrpc.Id, messages: std.ArrayList([]u8) = .empty };

/// How many messages apart from any request are kept for a reader; the oldest notification goes past that.
const unrelated_max = 1024;

pub const Router = struct {
    gpa: Allocator,
    host: *const Host,
    lock: Io.Mutex = .init,
    arrived: Io.Condition = .init,
    mailboxes: std.ArrayList(*Mailbox) = .empty,
    unrelated: std.ArrayList(Kept) = .empty,
    closed: bool = false,
    /// Why the channel closed, where its server went away, for whoever waits.
    reason: ?[]u8 = null,

    pub fn init(gpa: Allocator, host: *const Host) Router {
        return .{ .gpa = gpa, .host = host };
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
        router.lock.lockUncancelable(router.host.io);
        defer router.lock.unlock(router.host.io);
        try router.mailboxes.append(router.gpa, mailbox);
        return mailbox;
    }

    /// Closes a mailbox, what it holds dropped.
    pub fn close(router: *Router, mailbox: *Mailbox) void {
        {
            router.lock.lockUncancelable(router.host.io);
            defer router.lock.unlock(router.host.io);
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

    /// Takes a message from the server: to its request's mailbox where it has one, else apart; one that is no message
    /// is dropped, as a server must not send one.
    pub fn arrive(router: *Router, text: []const u8) Allocator.Error!void {
        var scratch: std.heap.ArenaAllocator = .init(router.gpa);
        defer scratch.deinit();
        const message = jsonrpc.parseOne(scratch.allocator(), text) catch return;
        router.lock.lockUncancelable(router.host.io);
        defer router.lock.unlock(router.host.io);
        if (router.closed) return;
        defer router.arrived.broadcast(router.host.io);
        if (transport_.relatedId(message)) |id| {
            for (router.mailboxes.items) |mailbox| if (mailbox.id.eql(id)) return mailbox.messages.append(router.gpa, try router.gpa.dupe(u8, text));
            if (message != .notification) return;
        }
        if (router.unrelated.items.len == unrelated_max) {
            for (router.unrelated.items, 0..) |kept, index| if (!kept.is_request) {
                router.gpa.free(router.unrelated.orderedRemove(index).text);
                break;
            };
        }
        try router.unrelated.append(router.gpa, .{ .text = try router.gpa.dupe(u8, text), .is_request = message == .request });
    }

    /// Closes the channel; `reason`, where the server went away, says why to whoever waits.
    pub fn shut(router: *Router, reason: ?[]const u8) void {
        router.lock.lockUncancelable(router.host.io);
        defer router.lock.unlock(router.host.io);
        if (router.closed) return;
        router.closed = true;
        if (reason) |given| router.reason = router.gpa.dupe(u8, given) catch null;
        router.arrived.broadcast(router.host.io);
    }

    pub fn isClosed(router: *Router) bool {
        router.lock.lockUncancelable(router.host.io);
        defer router.lock.unlock(router.host.io);
        return router.closed;
    }

    /// The channel's end, as an incoming, its reason in the slot's arena.
    fn ended(router: *Router, slot: *Slot) Allocator.Error!Incoming {
        return .{ .closed = if (router.reason) |reason| try slot.arena.dupe(u8, reason) else null };
    }

    /// The next message for `mailbox`'s request, or a server's own request, waiting at most `wait_ms`.
    pub fn next(router: *Router, mailbox: *Mailbox, slot: *Slot, wait_ms: ?u64) Error!Incoming {
        router.lock.lockUncancelable(router.host.io);
        defer router.lock.unlock(router.host.io);
        var waited = false;
        while (true) {
            if (mailbox.messages.items.len > 0) {
                const text = mailbox.messages.orderedRemove(0);
                defer router.gpa.free(text);
                return .{ .message = .{ .message = try decoded(slot, text) } };
            }
            for (router.unrelated.items, 0..) |kept, index| if (kept.is_request) {
                const taken = router.unrelated.orderedRemove(index);
                defer router.gpa.free(taken.text);
                return .{ .message = .{ .message = try decoded(slot, taken.text), .related = false } };
            };
            if (router.closed) return router.ended(slot);
            if (waited) return .quiet;
            waited = true;
            if (!(router.wait(wait_ms) catch return slot.fail(.canceled))) return .quiet;
        }
    }

    /// The next message apart from any request, waiting at most `wait_ms`.
    pub fn receive(router: *Router, slot: *Slot, wait_ms: ?u64) Error!Incoming {
        router.lock.lockUncancelable(router.host.io);
        defer router.lock.unlock(router.host.io);
        var waited = false;
        while (true) {
            if (router.unrelated.items.len > 0) {
                const kept = router.unrelated.orderedRemove(0);
                defer router.gpa.free(kept.text);
                return .{ .message = .{ .message = try decoded(slot, kept.text), .related = false } };
            }
            if (router.closed) return router.ended(slot);
            if (waited) return .quiet;
            waited = true;
            if (!(router.wait(wait_ms) catch return slot.fail(.canceled))) return .quiet;
        }
    }

    /// Waits for what comes, the lock held but while it waits; false where `wait_ms` passed.
    fn wait(router: *Router, wait_ms: ?u64) error{Canceled}!bool {
        const io = router.host.io;
        if (router.host.sleeper) |sleeper| {
            // Nothing comes but what a task sends; a test's sleep moves its clock on by the wait.
            router.lock.unlock(io);
            defer router.lock.lockUncancelable(io);
            try sleeper.sleep(wait_ms orelse return error.Canceled);
            return true;
        }
        const ms = wait_ms orelse {
            try router.arrived.wait(io, &router.lock);
            return true;
        };
        router.arrived.waitTimeout(io, &router.lock, .{ .duration = .{ .raw = .fromMilliseconds(@intCast(ms)), .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => return false,
            error.Canceled => return error.Canceled,
        };
        return true;
    }
};

fn decoded(slot: *Slot, text: []const u8) Error!jsonrpc.Message {
    return jsonrpc.parseOne(slot.arena, text) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // What the router keeps it read once already.
        error.NotJsonRpc => unreachable,
    };
}
