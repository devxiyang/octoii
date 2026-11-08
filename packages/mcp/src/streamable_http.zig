//! The Streamable HTTP transport: one POST a message to the server's MCP endpoint, each request answered with JSON or
//! an SSE stream of its own, which its caller reads. For a stateless server, the request's metadata mirrored into
//! headers (`MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`, `Mcp-Param-*`), and a stream closed as its cancellation.
//! For a session-based server, the `Mcp-Session-Id` session, a stream that breaks resumed from its last event with
//! `Last-Event-ID`, the GET stream of the server's own messages, and `notifications/cancelled`. Requests go through
//! the host's HTTP; the transport adds no credentials but the headers it is given.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const http = foundation.http;
const Header = http.Header;
const jsonrpc = @import("jsonrpc.zig");
const protocol = @import("protocol.zig");
const headers_ = @import("headers.zig");
const transport_ = @import("transport.zig");
const Host = transport_.Host;
const Incoming = transport_.Incoming;
const failure_ = @import("failure.zig");
const Slot = failure_.Slot;
const Error = failure_.Error;

pub const Options = struct {
    /// The server's MCP endpoint.
    url: []const u8,
    /// Headers every request carries besides the protocol's own, such as its credentials.
    headers: []const Header = &.{},
    /// How long to wait before opening a broken stream again when the server set no `retry`.
    reconnect_delay_ms: u64 = protocol.reconnect_delay_ms,
    /// How many times in a row a broken stream is opened again before it is given up.
    reconnects_max: u32 = protocol.reconnects_max,
};

pub const StreamableHttp = struct {
    gpa: Allocator,
    host: *const Host,
    network: http.Http,
    /// The options, and the version settled on, as long as the transport.
    lasting: std.heap.ArenaAllocator,
    options: Options,
    /// Guards what follows.
    lock: std.Io.Mutex = .init,
    era: ?protocol.Era = null,
    version: ?[]const u8 = null,
    session_id: ?[]u8 = null,
    closed: bool = false,
    /// The GET stream of a session-based server's own messages, and where it left off.
    listening: ?*Stream = null,
    listen_from: ?[]u8 = null,
    /// Whether the server said it sends nothing on its own (405), so no GET stream is opened.
    listen_refused: bool = false,

    pub fn init(gpa: Allocator, host: *const Host, network: http.Http, options: Options) Allocator.Error!*StreamableHttp {
        const made = try gpa.create(StreamableHttp);
        made.* = .{ .gpa = gpa, .host = host, .network = network, .lasting = .init(gpa), .options = undefined };
        const lasting = made.lasting.allocator();
        const headers = try lasting.alloc(Header, options.headers.len);
        for (options.headers, headers) |header, *copy| copy.* = .{ .name = try lasting.dupe(u8, header.name), .value = try lasting.dupe(u8, header.value) };
        made.options = .{ .url = try lasting.dupe(u8, options.url), .headers = headers, .reconnect_delay_ms = options.reconnect_delay_ms, .reconnects_max = options.reconnects_max };
        return made;
    }

    pub fn transport(self: *StreamableHttp) transport_.Transport {
        return .{ .context = self, .vtable = &.{ .request = request, .send = send, .receive = receive, .negotiated = negotiated, .isClosed = isClosed, .close = close } };
    }

    fn of(context: *anyopaque) *StreamableHttp {
        return @ptrCast(@alignCast(context));
    }

    fn request(context: *anyopaque, slot: *Slot, message: jsonrpc.Request, sending: transport_.Sending) Error!transport_.Exchange {
        const self = of(context);
        const stream = try Stream.create(self, message.id, sending.idle_ms);
        errdefer stream.destroy();
        try self.post(slot, .{ .request = message }, sending.headers, stream);
        return .{ .context = stream, .vtable = &.{ .next = Stream.next, .cancel = Stream.cancel, .close = Stream.close } };
    }

    fn send(context: *anyopaque, slot: *Slot, message: jsonrpc.Message) Error!void {
        try of(context).post(slot, message, &.{}, null);
    }

    /// POSTs `message` and takes its answer: into `stream` for a request, read on by its caller, or as a refusal.
    fn post(self: *StreamableHttp, slot: *Slot, message: jsonrpc.Message, extra: []const Header, stream: ?*Stream) Error!void {
        if (self.isShut()) return slot.fail(.{ .connection_lost = "The transport is closed" });
        const response = try self.sent(slot, .{
            .method = .POST,
            .url = self.options.url,
            .headers = try self.postHeaders(slot.arena, message, extra),
            .body = try message.encode(slot.arena),
            .wait = if (stream) |given| waitOf(given.idle_ms) else null,
        });
        try self.answer(slot, response, stream);
    }

    /// Sends one HTTP request; a network failure closes the transport, as the server is gone.
    fn sent(self: *StreamableHttp, slot: *Slot, given: http.Request) Error!http.Response {
        return self.network.send(given) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => slot.fail(.canceled),
            error.Transport, error.Timeout => {
                self.shut();
                return slot.fail(.{ .connection_lost = try std.fmt.allocPrint(slot.arena, "The MCP server at {s} could not be reached", .{self.options.url}) });
            },
        };
    }

    /// Takes a POST's answer: its JSON or its SSE stream for a request, an accepted notification, or why it failed.
    fn answer(self: *StreamableHttp, slot: *Slot, response: http.Response, stream: ?*Stream) Error!void {
        var keep = false;
        defer if (!keep) response.close();
        try self.tookSession(response);
        if (response.status == 404 and self.inSession()) {
            self.shut();
            return slot.fail(.{ .session_ended = "The MCP server ended the session" });
        }
        if (response.status == 401 or response.status == 403) {
            return slot.fail(.{ .unauthorized = .{ .status = response.status, .www_authenticate = if (response.header("www-authenticate")) |value| try slot.arena.dupe(u8, value) else null } });
        }
        const ok = response.status >= 200 and response.status < 300;
        const given = stream orelse return if (ok) {} else slot.fail(.{ .http = .{ .status = response.status, .body = try bodyOf(slot.arena, response) } });
        if (ok and isEventStream(response)) {
            keep = true;
            return given.attach(response);
        }
        const body = try bodyOf(slot.arena, response);
        if (ok) return given.queueAll(body, true);
        if (try errorAnswer(slot.arena, body, given.id)) |refusal| return given.queueAll(refusal, true);
        return slot.fail(.{ .http = .{ .status = response.status, .body = body } });
    }

    fn tookSession(self: *StreamableHttp, response: http.Response) Allocator.Error!void {
        const id = response.header("mcp-session-id") orelse return;
        self.lock.lockUncancelable(self.host.io);
        defer self.lock.unlock(self.host.io);
        if (self.era == .modern) return;
        if (self.session_id) |old| self.gpa.free(old);
        self.session_id = try self.gpa.dupe(u8, id);
    }

    fn inSession(self: *StreamableHttp) bool {
        self.lock.lockUncancelable(self.host.io);
        defer self.lock.unlock(self.host.io);
        return self.era == .legacy and self.session_id != null;
    }

    fn isShut(self: *StreamableHttp) bool {
        self.lock.lockUncancelable(self.host.io);
        defer self.lock.unlock(self.host.io);
        return self.closed;
    }

    fn shut(self: *StreamableHttp) void {
        self.lock.lockUncancelable(self.host.io);
        defer self.lock.unlock(self.host.io);
        self.closed = true;
    }

    /// A POST's headers: the transport's, the request's, the session's, and the request's metadata mirrored.
    fn postHeaders(self: *StreamableHttp, arena: Allocator, message: jsonrpc.Message, extra: []const Header) Allocator.Error![]const Header {
        var made: std.ArrayList(Header) = .empty;
        try set(arena, &made, self.options.headers);
        try set(arena, &made, extra);
        try set(arena, &made, try self.sessionHeaders(arena));
        try set(arena, &made, &.{ .{ .name = "content-type", .value = "application/json" }, .{ .name = "accept", .value = "application/json, text/event-stream" } });
        const settled = try self.settledVersion(arena);
        const version = settled orelse requestVersion(message);
        if (version) |given| try set(arena, &made, &.{.{ .name = "mcp-protocol-version", .value = given }});
        const method, const params = switch (message) {
            .request => |given| .{ given.method, given.params },
            .notification => |given| .{ given.method, given.params },
            else => return made.items,
        };
        try set(arena, &made, &.{.{ .name = "mcp-method", .value = method }});
        if (mirroredName(method, params)) |name| try set(arena, &made, &.{.{ .name = "mcp-name", .value = try headers_.headerValue(arena, name) }});
        return made.items;
    }

    fn settledVersion(self: *StreamableHttp, arena: Allocator) Allocator.Error!?[]const u8 {
        self.lock.lockUncancelable(self.host.io);
        defer self.lock.unlock(self.host.io);
        return if (self.version) |given| try arena.dupe(u8, given) else null;
    }

    fn sessionHeaders(self: *StreamableHttp, arena: Allocator) Allocator.Error![]const Header {
        self.lock.lockUncancelable(self.host.io);
        defer self.lock.unlock(self.host.io);
        var made: std.ArrayList(Header) = .empty;
        if (self.session_id) |id| try made.append(arena, .{ .name = "mcp-session-id", .value = try arena.dupe(u8, id) });
        if (self.version) |given| try made.append(arena, .{ .name = "mcp-protocol-version", .value = try arena.dupe(u8, given) });
        return made.items;
    }

    /// A GET's headers, from where a stream left off where it did.
    fn streamHeaders(self: *StreamableHttp, arena: Allocator, last_event_id: ?[]const u8) Allocator.Error![]const Header {
        var made: std.ArrayList(Header) = .empty;
        try set(arena, &made, self.options.headers);
        try set(arena, &made, try self.sessionHeaders(arena));
        try set(arena, &made, &.{.{ .name = "accept", .value = "text/event-stream" }});
        if (last_event_id) |id| try set(arena, &made, &.{.{ .name = "last-event-id", .value = id }});
        return made.items;
    }

    /// Opens a GET stream, resuming from `last_event_id` where it is given; null where the server gives none, as
    /// with 405. A session the server ended closes the transport.
    fn opened(self: *StreamableHttp, slot: *Slot, last_event_id: ?[]const u8, idle_ms: ?u64) Error!?http.Response {
        const response = try self.sent(slot, .{ .url = self.options.url, .headers = try self.streamHeaders(slot.arena, last_event_id), .wait = waitOf(idle_ms) });
        if (response.status == 404 and self.inSession()) {
            response.close();
            self.shut();
            return slot.fail(.{ .session_ended = "The MCP server ended the session" });
        }
        if (response.status < 200 or response.status >= 300 or !isEventStream(response)) {
            if (response.status == 405) self.refuseListening();
            response.close();
            return null;
        }
        return response;
    }

    fn refuseListening(self: *StreamableHttp) void {
        self.lock.lockUncancelable(self.host.io);
        defer self.lock.unlock(self.host.io);
        self.listen_refused = true;
    }

    /// The next message a session-based server sends on its own, on its GET stream, waiting at most `wait_ms`; a
    /// stateless server sends none apart.
    fn receive(context: *anyopaque, slot: *Slot, wait_ms: ?u64) Error!Incoming {
        const self = of(context);
        self.lock.lockUncancelable(self.host.io);
        const listens = self.era == .legacy and !self.listen_refused and !self.closed;
        const closed = self.closed;
        self.lock.unlock(self.host.io);
        if (closed) return .{ .closed = null };
        if (!listens) {
            self.host.sleep(wait_ms orelse return .quiet) catch return slot.fail(.canceled);
            return .quiet;
        }
        if (self.listening == null) {
            const stream = try Stream.create(self, null, wait_ms);
            const response = try self.opened(slot, self.listen_from, wait_ms) orelse {
                stream.destroy();
                return .quiet;
            };
            try stream.attach(response);
            self.listening = stream;
        }
        const stream = self.listening.?;
        const incoming = try Stream.next(stream, slot, wait_ms);
        if (incoming == .message) return incoming;
        // The stream fell silent or ended: it is opened again from where it left off at the next receive.
        if (stream.last_event_id) |id| {
            if (self.listen_from) |old| self.gpa.free(old);
            self.listen_from = try self.gpa.dupe(u8, id);
        }
        stream.destroy();
        self.listening = null;
        return if (incoming == .closed) incoming else .quiet;
    }

    fn isClosed(context: *anyopaque) bool {
        return of(context).isShut();
    }

    fn negotiated(context: *anyopaque, version: []const u8, era: protocol.Era) void {
        const self = of(context);
        self.lock.lockUncancelable(self.host.io);
        defer self.lock.unlock(self.host.io);
        self.version = self.lasting.allocator().dupe(u8, version) catch null;
        self.era = era;
        if (era == .modern) if (self.session_id) |id| {
            self.gpa.free(id);
            self.session_id = null;
        };
    }

    /// Ends a session with DELETE, and lets the transport go.
    fn close(context: *anyopaque) void {
        const self = of(context);
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        if (self.inSession() and !self.isShut()) {
            if (self.sessionHeaders(scratch.allocator())) |given| {
                if (self.network.send(.{ .method = .DELETE, .url = self.options.url, .headers = given })) |response| response.close() else |_| {}
            } else |_| {}
        }
        self.shut();
        if (self.listening) |stream| stream.destroy();
        if (self.listen_from) |id| self.gpa.free(id);
        if (self.session_id) |id| self.gpa.free(id);
        self.lasting.deinit();
        self.gpa.destroy(self);
    }
};

/// What comes back for one request, or on the GET stream: an SSE stream read as it comes, or the messages of a JSON
/// answer; a session's stream that breaks before its answer resumed from its last event.
const Stream = struct {
    owner: *StreamableHttp,
    /// The request it answers; none for the GET stream.
    id: ?jsonrpc.Id,
    idle_ms: ?u64,
    arena: std.heap.ArenaAllocator,
    response: ?http.Response = null,
    events: ?foundation.sse.Reader = null,
    /// Messages read and not yet given, as JSON text.
    queued: std.ArrayList([]const u8) = .empty,
    taken: usize = 0,
    /// Whether no more comes but what is queued, as of a JSON answer.
    whole: bool = false,
    answered: bool = false,
    last_event_id: ?[]const u8 = null,
    retry_ms: ?u64 = null,
    resumes: u32 = 0,

    fn create(owner: *StreamableHttp, id: ?jsonrpc.Id, idle_ms: ?u64) Allocator.Error!*Stream {
        const stream = try owner.gpa.create(Stream);
        stream.* = .{ .owner = owner, .id = null, .idle_ms = idle_ms, .arena = .init(owner.gpa) };
        if (id) |given| stream.id = switch (given) {
            .number => given,
            .string => |text| .{ .string = try stream.arena.allocator().dupe(u8, text) },
        };
        return stream;
    }

    fn destroy(stream: *Stream) void {
        stream.detach();
        const gpa = stream.owner.gpa;
        stream.arena.deinit();
        gpa.destroy(stream);
    }

    fn attach(stream: *Stream, response: http.Response) Allocator.Error!void {
        stream.response = response;
        stream.events = .init(stream.arena.allocator(), response.body);
    }

    fn detach(stream: *Stream) void {
        if (stream.events) |*events| events.deinit();
        stream.events = null;
        if (stream.response) |response| response.close();
        stream.response = null;
    }

    /// Queues the messages of `text`, a JSON answer or an event's data; text that is none, as a priming event's, holds
    /// none.
    fn queueAll(stream: *Stream, text: []const u8, whole: bool) Allocator.Error!void {
        stream.whole = whole;
        var scratch: std.heap.ArenaAllocator = .init(stream.owner.gpa);
        defer scratch.deinit();
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) return;
        const messages = jsonrpc.parse(scratch.allocator(), text) catch return;
        for (messages) |message| try stream.queued.append(stream.arena.allocator(), try message.encode(stream.arena.allocator()));
    }

    fn of(context: *anyopaque) *Stream {
        return @ptrCast(@alignCast(context));
    }

    fn next(context: *anyopaque, slot: *Slot, wait_ms: ?u64) Error!Incoming {
        const stream = Stream.of(context);
        _ = wait_ms;
        while (true) {
            if (stream.taken < stream.queued.items.len) {
                defer stream.taken += 1;
                const message = jsonrpc.parseOne(slot.arena, stream.queued.items[stream.taken]) catch unreachable;
                if (stream.id) |id| if (message.answers()) |answered| if (answered.eql(id)) {
                    stream.answered = true;
                };
                return .{ .message = .{ .message = message } };
            }
            if (stream.answered) return .quiet;
            if (stream.owner.isShut()) return .{ .closed = null };
            if (stream.whole) return .lost;
            if (stream.events == null) {
                if (!try stream.reopened(slot)) return .lost;
                continue;
            }
            const event = stream.events.?.next() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ReadFailed => {
                    const silent = stream.response.?.failure() == error.Timeout;
                    stream.detach();
                    if (silent) return .quiet;
                    continue;
                },
            } orelse {
                stream.detach();
                continue;
            };
            stream.resumes = 0;
            if (event.id) |id| stream.last_event_id = try stream.arena.allocator().dupe(u8, id);
            if (event.retry) |retry| stream.retry_ms = retry;
            try stream.queueAll(event.data, false);
        }
    }

    /// Opens a broken stream of a session-based server again from its last event, after the server's `retry` or the
    /// default delay; false where it cannot be resumed.
    fn reopened(stream: *Stream, slot: *Slot) Error!bool {
        const owner = stream.owner;
        const id = stream.last_event_id orelse return false;
        if (!owner.inSession() or stream.resumes >= owner.options.reconnects_max) return false;
        stream.resumes += 1;
        owner.host.sleep(stream.retry_ms orelse owner.options.reconnect_delay_ms) catch return slot.fail(.canceled);
        const response = owner.opened(slot, id, stream.idle_ms) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Failed => if (slot.failure.? == .session_ended) return err else {
                slot.failure = null;
                return false;
            },
        } orelse return false;
        try stream.attach(response);
        return true;
    }

    /// Cancels the request: a stateless server takes its closed stream as the cancellation; one with sessions is told.
    fn cancel(context: *anyopaque, reason: []const u8) void {
        const stream = Stream.of(context);
        const owner = stream.owner;
        owner.lock.lockUncancelable(owner.host.io);
        const tells = owner.era != .modern and !owner.closed;
        owner.lock.unlock(owner.host.io);
        stream.detach();
        if (tells) if (stream.id) |id| {
            var scratch: std.heap.ArenaAllocator = .init(owner.gpa);
            defer scratch.deinit();
            var slot: Slot = .{ .arena = scratch.allocator() };
            if (transport_.cancelledNotification(scratch.allocator(), id, reason)) |cancelled| owner.post(&slot, cancelled, &.{}, null) catch {} else |_| {}
        };
        stream.destroy();
    }

    fn close(context: *anyopaque) void {
        Stream.of(context).destroy();
    }
};

fn waitOf(idle_ms: ?u64) ?http.Wait {
    const ms = idle_ms orelse return null;
    return .{ .head_ms = ms, .idle_ms = ms };
}

/// Sets each of `given` among `headers`, in place of one of its name.
fn set(arena: Allocator, headers: *std.ArrayList(Header), given: []const Header) Allocator.Error!void {
    for (given) |header| {
        for (headers.items) |*each| {
            if (!std.ascii.eqlIgnoreCase(each.name, header.name)) continue;
            each.value = header.value;
            break;
        } else try headers.append(arena, header);
    }
}

fn isEventStream(response: http.Response) bool {
    const kind = response.header("content-type") orelse return false;
    return std.ascii.startsWithIgnoreCase(std.mem.trim(u8, kind, " "), "text/event-stream");
}

fn bodyOf(arena: Allocator, response: http.Response) Allocator.Error![]const u8 {
    return response.body.allocRemaining(arena, .limited(16 << 20)) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => "",
    };
}

/// The protocol version a stateless request names in its metadata.
fn requestVersion(message: jsonrpc.Message) ?[]const u8 {
    const params = switch (message) {
        .request => |given| given.params,
        .notification => |given| given.params,
        else => null,
    } orelse return null;
    if (params != .object) return null;
    const meta = params.object.get("_meta") orelse return null;
    if (meta != .object) return null;
    const version = meta.object.get(protocol.meta.protocol_version) orelse return null;
    return if (version == .string) version.string else null;
}

/// What `Mcp-Name` mirrors: the name of a tool or prompt, or the URI of a resource.
fn mirroredName(method: []const u8, params: ?std.json.Value) ?[]const u8 {
    const given = params orelse return null;
    if (given != .object) return null;
    const key = if (std.mem.eql(u8, method, "tools/call") or std.mem.eql(u8, method, "prompts/get")) "name" else if (std.mem.eql(u8, method, "resources/read")) "uri" else return null;
    const value = given.object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

/// The JSON-RPC error an HTTP error's body carries for the request `id`, as JSON text with its id: one that names the
/// request, or one of the codes only a stateless server answers with; null for anything else, left to the status.
fn errorAnswer(arena: Allocator, body: []const u8, id: ?jsonrpc.Id) Allocator.Error!?[]const u8 {
    const request = id orelse return null;
    const messages = jsonrpc.parse(arena, body) catch return null;
    const failed = switch (messages[0]) {
        .failure => |given| given,
        else => return null,
    };
    const names = if (failed.id) |given| given.eql(request) else false;
    if (!names and !protocol.isModernCode(failed.@"error".code)) return null;
    return try (jsonrpc.Message{ .failure = .{ .id = request, .@"error" = failed.@"error" } }).encode(arena);
}
