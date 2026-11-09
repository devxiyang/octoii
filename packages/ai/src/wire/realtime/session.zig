//! What every realtime transcription protocol shares over its WebSocket: the provider's messages read into the
//! vocabulary's events and kept for the caller, the caller's events written as the protocol's messages, a keep-alive
//! for a provider that closes a silent connection, and the session's end — by `close()`, once the protocol says all it
//! asked is answered or its provider closes the socket; unasked, as the provider's last `error`, else `transport`; or
//! out of time, before it opens or after `close()`.
//!
//! A caller reads the events with `poll` or `next`, one task at a time, and may send and close from another task
//! meanwhile. The session's waits run while it is read: a read waits on the socket no longer than the next of them,
//! so a caller that reads keeps the connection alive and is told when time runs out.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const websocket = foundation.websocket;
const vocabulary = @import("vocabulary");
const realtime = vocabulary.realtime;
const ServerEvent = realtime.ServerEvent;
const ClientEvent = realtime.ClientEvent;
const RealtimeError = realtime.RealtimeError;
const driver = @import("../../driver.zig");
const failure_ = @import("../../failure.zig");
const Failure = failure_.Failure;
const text_stream = @import("../../text/stream.zig");

/// How long a session may send nothing before a protocol with a keep-alive sends it.
pub const keep_alive_ms = 4_000;

/// How long a session may take to open, and its transcriptions to complete once it is closed.
pub const response_timeout_ms = text_stream.start_timeout_ms;

pub const Error = error{ OutOfMemory, Broken };

/// What a step of a protocol makes: the messages it puts on the socket, and the events it gives the caller itself.
pub const Out = struct {
    /// Where the events it gives live, until the caller has read them.
    arena: Allocator,
    /// Where the messages it sends live, until they are sent.
    scratch_arena: Allocator,
    messages: std.ArrayList(websocket.Message) = .empty,
    events: std.ArrayList(ServerEvent) = .empty,
    /// Why the provider's message broke its protocol, where one did.
    broken: ?[]const u8 = null,

    pub fn send(out: *Out, message: websocket.Message) Allocator.Error!void {
        try out.messages.append(out.scratch_arena, message);
    }

    pub fn give(out: *Out, event: ServerEvent) Allocator.Error!void {
        try out.events.append(out.arena, event);
    }

    /// Fails the step, the provider's message having broken its protocol as `text` says.
    pub fn brokenBy(out: *Out, comptime text: []const u8, arguments: anytype) Error {
        out.broken = try out.arena.print(text, arguments);
        return error.Broken;
    }
};

/// How one provider's realtime transcription speaks over its socket.
pub const Wire = struct {
    context: *anyopaque,
    vtable: *const VTable,
    /// The event whose coming opens the session, once the provider has taken its settings; none, open at once.
    opens_on: ?std.meta.Tag(ServerEvent) = null,
    /// The message that keeps a silent connection open, for a provider that closes one.
    keep_alive: ?websocket.Message = null,

    pub const VTable = struct {
        /// What goes on the socket as it opens, and the events given first, such as a `session.created`.
        start: *const fn (context: *anyopaque, out: *Out) Error!void,
        /// The events a message from the provider stands for; `Broken` for one that breaks its protocol.
        read: *const fn (context: *anyopaque, out: *Out, message: websocket.Message) Error!void,
        /// What a client event goes on the socket as, or the events that answer it at once, such as an `error`.
        write: *const fn (context: *anyopaque, out: *Out, event: ClientEvent) Error!void,
        /// What goes on the socket as the caller closes the session: the audio not yet committed, committed.
        close: *const fn (context: *anyopaque, out: *Out) Error!void,
        /// Whether, once closing, all the protocol asked is answered, so that the session closes the socket; false
        /// where its provider closes it.
        settled: *const fn (context: *anyopaque) bool,
        /// The events that end what is left once the provider closed the socket after `close()`.
        ended: *const fn (context: *anyopaque, out: *Out) Error!void,
        deinit: *const fn (context: *anyopaque) void,
    };
};

/// Numbers the ids a protocol gives its own events, items and segments: `event_1`, `item_1` and on, one series each.
pub const Ids = struct {
    events: u64 = 0,
    items: u64 = 0,
    segments: u64 = 0,

    pub fn event(ids: *Ids, arena: Allocator) Allocator.Error![]const u8 {
        ids.events += 1;
        return arena.print("event_{d}", .{ids.events});
    }

    /// The next item's number; `itemId` names it.
    pub fn item(ids: *Ids) u64 {
        ids.items += 1;
        return ids.items;
    }

    pub fn segment(ids: *Ids, arena: Allocator) Allocator.Error![]const u8 {
        ids.segments += 1;
        return arena.print("segment_{d}", .{ids.segments});
    }
};

pub fn itemId(arena: Allocator, number: u64) Allocator.Error![]const u8 {
    return arena.print("item_{d}", .{number});
}

/// A `RealtimeError` of `kind` that Octoii itself answers a client event with, as a provider answers one it does not
/// take; its code the kind's where `code` is none.
pub fn realtimeError(kind: failure_.Kind, message: []const u8, code: ?[]const u8) RealtimeError {
    return .{
        .type = if (kind == .invalid_request) "invalid_request_error" else "server_error",
        .code = .{ .value = code orelse @tagName(kind) },
        .message = message,
        .octoii = .{ .kind = kind, .retryable = failure_.retryableKind(kind) },
    };
}

/// An `error` event of `kind`, its message formatted, numbered from `ids`.
pub fn errorEvent(arena: Allocator, ids: *Ids, kind: failure_.Kind, comptime text: []const u8, arguments: anytype) Allocator.Error!ServerEvent {
    const message = try arena.print(text, arguments);
    return .{ .@"error" = .{ .@"error" = realtimeError(kind, message, null), .event_id = try ids.event(arena) } };
}

/// What a read of the session came to: an event, nothing within its wait, or the session's end.
pub const Polled = union(enum) {
    event: ServerEvent,
    quiet,
    ended,
};

/// A session over a socket: the provider's events kept until the caller reads them, and what the caller sends
/// written.
pub const Session = struct {
    gpa: Allocator,
    host: *const driver.Host,
    socket: websocket.Socket,
    wire: Wire,
    /// Guards all that follows, but for `received`, which the one reading task keeps.
    lock: std.Io.Mutex = .init,
    /// The events kept and what they hold, until the caller has read them all.
    events_arena: std.heap.ArenaAllocator,
    kept: std.ArrayList(ServerEvent) = .empty,
    taken: usize = 0,
    /// What a read receives, until the next read.
    received_arena: std.heap.ArenaAllocator,
    /// What a send writes, until the next send.
    sending_arena: std.heap.ArenaAllocator,
    /// The failures, which last as long as the session.
    failures_arena: std.heap.ArenaAllocator,
    is_open: bool,
    closing: bool = false,
    /// Whether the session closed the socket itself, once all it asked was answered.
    closed_by_session: bool = false,
    ended: bool = false,
    /// What ended the session, where a failure did.
    failure: ?Failure = null,
    /// The failure of the provider's last `error`, which a provider that ends a session sends before it closes.
    last_error: ?Failure = null,
    last_sent_ms: i64,
    open_by_ms: i64,
    close_by_ms: ?i64 = null,

    /// A session `wire` speaks over `socket`, which it owns from here: what the wire starts with sent and kept.
    pub fn start(gpa: Allocator, host: *const driver.Host, socket: websocket.Socket, wire: Wire) Allocator.Error!*Session {
        const session = gpa.create(Session) catch |err| {
            socket.close();
            socket.deinit();
            wire.vtable.deinit(wire.context);
            return err;
        };
        errdefer gpa.destroy(session);
        const now = host.nowMs();
        session.* = .{
            .gpa = gpa,
            .host = host,
            .socket = socket,
            .wire = wire,
            .events_arena = .init(gpa),
            .received_arena = .init(gpa),
            .sending_arena = .init(gpa),
            .failures_arena = .init(gpa),
            .is_open = wire.opens_on == null,
            .last_sent_ms = now,
            .open_by_ms = now + response_timeout_ms,
        };
        session.lock.lockUncancelable(host.io);
        defer session.lock.unlock(host.io);
        var out = session.outOf(session.sending_arena.allocator());
        session.wire.vtable.start(session.wire.context, &out) catch |err| session.failStep(err, &out);
        session.apply(&out);
        return session;
    }

    /// Lets the session go, its socket closed where it is open.
    pub fn deinit(session: *Session) void {
        session.socket.close();
        session.socket.deinit();
        session.wire.vtable.deinit(session.wire.context);
        session.kept.deinit(session.gpa);
        session.events_arena.deinit();
        session.received_arena.deinit();
        session.sending_arena.deinit();
        session.failures_arena.deinit();
        session.gpa.destroy(session);
    }

    /// Reads until the provider has taken the session's settings; the failure that ended it first, where one did.
    pub fn awaitOpen(session: *Session) ?Failure {
        session.lock.lockUncancelable(session.host.io);
        defer session.lock.unlock(session.host.io);
        while (!session.is_open and !session.ended) _ = session.step(null);
        if (session.is_open) return null;
        return session.failure orelse Failure.init(.transport, "The session ended before it opened");
    }

    /// The next event, waiting at most `wait_ms`; none, until one comes or the session ends. An event lives until the
    /// next read; the failure that ended the session, if one did, is `failure`.
    pub fn poll(session: *Session, wait_ms: ?u64) Polled {
        session.lock.lockUncancelable(session.host.io);
        defer session.lock.unlock(session.host.io);
        if (session.taken == session.kept.items.len) session.forgetRead();
        const until_ms: ?i64 = if (wait_ms) |ms| session.host.nowMs() + @as(i64, @intCast(ms)) else null;
        while (true) {
            if (session.taken < session.kept.items.len) {
                defer session.taken += 1;
                return .{ .event = session.kept.items[session.taken] };
            }
            if (session.ended) return .ended;
            if (!session.step(until_ms)) return .quiet;
        }
    }

    /// The next event, however long it takes; null once the session ends.
    pub fn next(session: *Session) ?ServerEvent {
        return switch (session.poll(null)) {
            .event => |event| event,
            .ended => null,
            .quiet => unreachable,
        };
    }

    /// Sends `event` to the provider; one the provider does not take is answered by an `error` event.
    pub fn send(session: *Session, event: ClientEvent) void {
        session.lock.lockUncancelable(session.host.io);
        defer session.lock.unlock(session.host.io);
        if (session.ended or session.closing) return;
        _ = session.sending_arena.reset(.retain_capacity);
        var out = session.outOf(session.sending_arena.allocator());
        session.wire.vtable.write(session.wire.context, &out, event) catch |err| return session.failStep(err, &out);
        session.apply(&out);
    }

    /// Commits the audio not yet committed; the events go on until its transcription completes.
    pub fn close(session: *Session) void {
        session.lock.lockUncancelable(session.host.io);
        defer session.lock.unlock(session.host.io);
        if (session.ended or session.closing) return;
        session.closing = true;
        session.close_by_ms = session.host.nowMs() + response_timeout_ms;
        _ = session.sending_arena.reset(.retain_capacity);
        var out = session.outOf(session.sending_arena.allocator());
        session.wire.vtable.close(session.wire.context, &out) catch |err| return session.failStep(err, &out);
        session.apply(&out);
        session.closeWhenSettled();
    }

    fn outOf(session: *Session, scratch_arena: Allocator) Out {
        return .{ .arena = session.events_arena.allocator(), .scratch_arena = scratch_arena };
    }

    /// Drops the events the caller has read, every one of them.
    fn forgetRead(session: *Session) void {
        session.kept.clearRetainingCapacity();
        session.taken = 0;
        _ = session.events_arena.reset(.retain_capacity);
    }

    /// Reads what comes next, waiting no longer than the session's next deadline or `until_ms`, the lock let go
    /// meanwhile; false where `until_ms` passed with nothing come.
    fn step(session: *Session, until_ms: ?i64) bool {
        const now = session.host.nowMs();
        const wait_until = earliest(session.dueMs(), until_ms);
        const wait: ?u64 = if (wait_until) |at| @intCast(@max(at - now, 0)) else null;
        _ = session.received_arena.reset(.retain_capacity);
        session.lock.unlock(session.host.io);
        const received = session.socket.receive(session.received_arena.allocator(), wait);
        session.lock.lockUncancelable(session.host.io);
        if (session.ended) return true;
        const got = received catch |err| {
            session.fail(switch (err) {
                error.Canceled => Failure.init(.aborted, "The session's read was canceled"),
                error.Transport => Failure.init(.transport, "The session's connection broke off"),
                error.OutOfMemory => Failure.init(.transport, "The session ran out of memory for a message"),
            });
            return true;
        };
        switch (got) {
            .message => |message| session.read(message),
            .closed => session.socketEnded(),
            .quiet => return session.lapsed(until_ms),
        }
        return true;
    }

    /// The next of the session's deadlines: its keep-alive's, its opening's, its close's.
    fn dueMs(session: *const Session) ?i64 {
        var due: ?i64 = null;
        if (session.wire.keep_alive != null and !session.closing) due = session.last_sent_ms + keep_alive_ms;
        if (!session.is_open) due = earliest(due, session.open_by_ms);
        if (session.close_by_ms) |by| due = earliest(due, by);
        return due;
    }

    /// What a wait that nothing ended comes to: the keep-alive sent, or the session out of time; false where the
    /// caller's wait, to `until_ms`, has run out.
    fn lapsed(session: *Session, until_ms: ?i64) bool {
        const now = session.host.nowMs();
        if (!session.is_open and now >= session.open_by_ms) {
            session.fail(Failure.init(.timeout, std.fmt.comptimePrint("The session did not open within {d} ms", .{response_timeout_ms})));
            return true;
        }
        if (session.close_by_ms) |by| if (now >= by) {
            session.fail(Failure.init(.timeout, std.fmt.comptimePrint("The session's transcriptions did not complete within {d} ms of its close", .{response_timeout_ms})));
            return true;
        };
        if (session.wire.keep_alive) |message| if (!session.closing and now >= session.last_sent_ms + keep_alive_ms) {
            session.socket.send(message) catch return session.brokenOff();
            session.last_sent_ms = now;
        };
        return if (until_ms) |until| now < until else true;
    }

    fn brokenOff(session: *Session) bool {
        session.fail(Failure.init(.transport, "The session's connection broke off"));
        return true;
    }

    /// Reads a message of the provider's into the events it stands for.
    fn read(session: *Session, message: websocket.Message) void {
        var out = session.outOf(session.received_arena.allocator());
        session.wire.vtable.read(session.wire.context, &out, message) catch |err| return session.failStep(err, &out);
        session.apply(&out);
        session.closeWhenSettled();
    }

    /// Ends the session with the failure of a protocol's step: the provider's message broke its protocol, or memory ran
    /// out.
    fn failStep(session: *Session, err: Error, out: *const Out) void {
        session.fail(switch (err) {
            error.Broken => .{ .kind = .invalid_response, .message = session.lasting(out.broken.?), .retryable = false },
            error.OutOfMemory => Failure.init(.transport, "The session ran out of memory"),
        });
    }

    /// Puts a step's messages on the socket and keeps its events, opening the session at its opening event.
    fn apply(session: *Session, out: *Out) void {
        for (out.messages.items) |message| session.socket.send(message) catch {
            _ = session.brokenOff();
            return;
        };
        if (out.messages.items.len > 0) session.last_sent_ms = session.host.nowMs();
        for (out.events.items) |event| {
            if (session.ended) return;
            if (event == .@"error") session.last_error = session.failureOf(event.@"error".@"error");
            session.kept.append(session.gpa, event) catch return session.fail(Failure.init(.transport, "The session ran out of memory for its events"));
            if (session.is_open) continue;
            if (session.wire.opens_on == std.meta.activeTag(event)) {
                session.is_open = true;
            } else if (event == .@"error") session.fail(session.last_error.?);
        }
    }

    /// Closes the socket once the caller has closed the session and the protocol has all it asked for.
    fn closeWhenSettled(session: *Session) void {
        if (!session.closing or session.ended or session.closed_by_session or !session.wire.vtable.settled(session.wire.context)) return;
        session.closed_by_session = true;
        session.socket.close();
        session.ended = true;
    }

    /// The end of the socket: the session's end after `close()`, else the provider's last failure or `transport`.
    fn socketEnded(session: *Session) void {
        if (!session.closing) return session.fail(session.last_error orelse Failure.init(.transport, "The session's connection ended unasked"));
        var out = session.outOf(session.received_arena.allocator());
        session.wire.vtable.ended(session.wire.context, &out) catch |err| return session.failStep(err, &out);
        session.apply(&out);
        session.ended = true;
    }

    /// Ends the session with `failure`, its socket closed.
    fn fail(session: *Session, failure: Failure) void {
        if (session.ended) return;
        session.ended = true;
        session.failure = failure;
        session.socket.close();
    }

    /// The failure a `RealtimeError` stands for, with the provider's code where it gives one, kept as long as the
    /// session.
    fn failureOf(session: *Session, given: RealtimeError) Failure {
        const code: ?[]const u8 = if (given.code) |code| code.given() else null;
        const own = code != null and std.mem.eql(u8, code.?, @tagName(given.octoii.kind));
        return .{
            .kind = given.octoii.kind,
            .message = session.lasting(given.message),
            .retryable = given.octoii.retryable,
            .retry_after_ms = given.octoii.retry_after_ms,
            .status = given.octoii.status,
            .code = if (code == null or own) null else session.lasting(code.?),
        };
    }

    /// `text` kept as long as the session; as it is, where memory runs out.
    fn lasting(session: *Session, text: []const u8) []const u8 {
        return session.failures_arena.allocator().dupe(u8, text) catch text;
    }
};

fn earliest(a: ?i64, b: ?i64) ?i64 {
    if (a == null) return b;
    if (b == null) return a;
    return @min(a.?, b.?);
}

/// The WebSocket address of `path` at the API `base_url`, its `http` as `ws`, with `query` already encoded.
pub fn socketUrl(arena: Allocator, base_url: []const u8, path: []const u8, query: []const u8) Allocator.Error![]const u8 {
    const scheme_rest = if (std.mem.startsWith(u8, base_url, "http")) base_url["http".len..] else base_url;
    const scheme = if (std.mem.startsWith(u8, base_url, "http")) "ws" else "";
    const separator: []const u8 = if (query.len == 0) "" else "?";
    return arena.print("{s}{s}{s}{s}{s}", .{ scheme, scheme_rest, path, separator, query });
}
