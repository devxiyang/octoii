//! The fake server over Streamable HTTP, as the host's HTTP in a test: POSTs answered with an SSE stream of their own
//! — read as it grows, so that what a session's answer sets going reaches the stream that waits for it — a session's
//! GET stream, a broken stream resumed from its last event, sessions that end, and bearer tokens refused. Each request
//! is kept with its headers.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const foundation = @import("foundation");
const http = foundation.http;
const Header = http.Header;
const jsonrpc = @import("../jsonrpc.zig");
const protocol = @import("../protocol.zig");
const headers_ = @import("../headers.zig");
const transport = @import("../transport.zig");
const server_ = @import("server.zig");
const FakeServer = server_.FakeServer;
const Channel = server_.Channel;

/// One SSE stream of the server: its events kept, so that a connection that broke resumes after the last it saw.
const Log = struct {
    id: []const u8,
    events: std.ArrayList([]const u8) = .empty,
    finished: bool = false,
    /// Over its first connection, how many events go before it breaks, as a network would.
    break_after: ?usize = null,
    /// The call it answers, which a closed stream cancels in the stateless protocol.
    request: ?jsonrpc.Id = null,
};

pub const HttpServer = struct {
    arena: Allocator,
    fake: *FakeServer,
    host: *const transport.Host,
    /// Every request, in order.
    requests: std.ArrayList(http.Request) = .empty,
    logs: std.ArrayList(*Log) = .empty,
    session_id: ?[]const u8 = null,
    next_session: usize = 1,
    /// How many events the next SSE answer sends before its connection breaks.
    break_after: ?usize = null,
    /// The token it takes, where it takes one: a request without it is answered 401.
    token: ?[]const u8 = null,
    /// Whether it is reachable.
    reachable: bool = true,

    pub fn init(arena: Allocator, fake: *FakeServer, host: *const transport.Host) HttpServer {
        return .{ .arena = arena, .fake = fake, .host = host };
    }

    pub fn network(server: *HttpServer) http.Http {
        return .{ .context = server, .vtable = &.{ .send = send } };
    }

    /// Ends the session, so that its next request is answered 404.
    pub fn expireSession(server: *HttpServer) void {
        server.session_id = null;
        server.fake.session.ended = true;
    }

    /// The headers of the request `index`, by name in any case.
    pub fn header(server: *const HttpServer, index: usize, name: []const u8) ?[]const u8 {
        return http.find(server.requests.items[index].headers, name);
    }

    fn of(context: *anyopaque) *HttpServer {
        return @ptrCast(@alignCast(context));
    }

    fn send(context: *anyopaque, request: http.Request) http.SendError!http.Response {
        const server = of(context);
        try server.requests.append(server.arena, try copied(server.arena, request));
        if (!server.reachable) return error.Transport;
        if (server.token) |token| {
            const given = http.find(request.headers, "authorization") orelse "";
            if (!std.mem.eql(u8, given, try std.fmt.allocPrint(server.arena, "Bearer {s}", .{token}))) {
                return server.respond(401, &.{.{ .name = "www-authenticate", .value = "Bearer resource_metadata=\"https://mcp.example/.well-known/oauth-protected-resource/mcp\", scope=\"tools\"" }}, .{ .text = "Unauthorized" });
            }
        }
        return switch (request.method) {
            .GET => server.get(request),
            .DELETE => server.delete(request),
            .POST => server.post(request),
            else => server.respond(405, &.{}, .{ .text = "" }),
        };
    }

    fn sessionOk(server: *const HttpServer, request: http.Request) bool {
        const given = http.find(request.headers, "mcp-session-id") orelse return false;
        return if (server.session_id) |id| std.mem.eql(u8, id, given) else false;
    }

    fn delete(server: *HttpServer, request: http.Request) Allocator.Error!http.Response {
        if (!server.sessionOk(request)) return server.respond(405, &.{}, .{ .text = "" });
        server.expireSession();
        return server.respond(200, &.{}, .{ .text = "" });
    }

    /// A session's GET stream: a broken stream resumed from `Last-Event-ID`, or the messages it sends on its own.
    fn get(server: *HttpServer, request: http.Request) Allocator.Error!http.Response {
        if (http.find(request.headers, "mcp-session-id") != null and !server.sessionOk(request)) return server.respond(404, &.{}, .{ .text = "" });
        if (server.fake.session.era != .legacy or !server.sessionOk(request)) return server.respond(405, &.{}, .{ .text = "" });
        if (http.find(request.headers, "last-event-id")) |last| {
            const slash = std.mem.lastIndexOfScalar(u8, last, '/') orelse last.len;
            for (server.logs.items) |log| if (std.mem.eql(u8, log.id, last[0..slash])) {
                const from = (std.fmt.parseInt(isize, last[slash + 1 ..], 10) catch -1) + 1;
                return server.streamed(log, @intCast(@max(from, 0)), false);
            };
        }
        const log = try server.newLog(null);
        server.fake.sink = server.channelOf(log);
        return server.streamed(log, 0, true);
    }

    fn post(server: *HttpServer, request: http.Request) Allocator.Error!http.Response {
        const body = request.body orelse "";
        const message = jsonrpc.parseOne(server.arena, body) catch return server.respond(400, &.{}, .{ .text = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}" });
        const version = modernVersion(message);
        var session_header: ?[]const u8 = null;
        if (version) |given| {
            if (try headerRefusal(server.arena, request, message, given)) |refusal| return server.respond(400, &.{}, .{ .text = refusal });
        } else if (message == .request and std.mem.eql(u8, message.request.method, "initialize")) {
            server.fake.session = .{};
            server.session_id = try std.fmt.allocPrint(server.arena, "session-{d}", .{server.next_session});
            server.next_session += 1;
            session_header = server.session_id;
        } else if (!server.sessionOk(request)) {
            if (http.find(request.headers, "mcp-session-id") != null) return server.respond(404, &.{}, .{ .text = "Session not found" });
            return server.respond(400, &.{}, .{ .text = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32000,\"message\":\"Bad Request: Server not initialized\"}}" });
        }
        if (message != .request) {
            const unrelated = server.fake.sink orelse server.channelOf(try server.newLog(null));
            server.fake.handleOn(unrelated, body);
            return server.respond(202, &.{}, .{ .text = "" });
        }
        const log = try server.newLog(message.request.id);
        log.break_after = server.break_after;
        server.break_after = null;
        server.fake.handleOn(server.channelOf(log), body);
        const extra: []const Header = if (session_header) |id| &.{.{ .name = "mcp-session-id", .value = id }} else &.{};
        return server.streamedWith(log, 0, true, extra);
    }

    fn newLog(server: *HttpServer, request: ?jsonrpc.Id) Allocator.Error!*Log {
        const log = try server.arena.create(Log);
        log.* = .{ .id = try std.fmt.allocPrint(server.arena, "stream-{d}", .{server.logs.items.len + 1}), .request = request };
        try server.logs.append(server.arena, log);
        return log;
    }

    fn channelOf(server: *HttpServer, log: *Log) Channel {
        const bound = server.arena.create(Bound) catch @panic("out of memory");
        bound.* = .{ .server = server, .log = log };
        return .{ .context = bound, .vtable = &.{ .send = Bound.send, .close = Bound.close } };
    }

    fn streamed(server: *HttpServer, log: *Log, from: usize, primed: bool) Allocator.Error!http.Response {
        return server.streamedWith(log, from, primed, &.{});
    }

    fn streamedWith(server: *HttpServer, log: *Log, from: usize, primed: bool, extra: []const Header) Allocator.Error!http.Response {
        const reading = try server.arena.create(Reading);
        const wait = server.requests.getLast().wait;
        reading.* = .{
            .server = server,
            .log = log,
            .next_event = from,
            .primed = !primed,
            .breaks = log.break_after,
            .idle_ms = if (wait) |given| given.idle_ms else null,
            .reader = .{ .vtable = &.{ .stream = Reading.stream }, .buffer = try server.arena.alloc(u8, 4096), .seek = 0, .end = 0 },
        };
        log.break_after = null;
        var headers: std.ArrayList(Header) = .empty;
        try headers.append(server.arena, .{ .name = "content-type", .value = "text/event-stream" });
        try headers.appendSlice(server.arena, extra);
        return .{ .status = 200, .headers = headers.items, .body = &reading.reader, .context = reading, .vtable = &.{ .failure = Reading.failure, .close = Reading.close } };
    }

    fn respond(server: *HttpServer, status: u16, headers: []const Header, body: struct { text: []const u8 }) Allocator.Error!http.Response {
        const chunks = try server.arena.alloc([]const u8, 1);
        chunks[0] = body.text;
        const reader = try server.arena.create(foundation.replay.ChunkReader);
        reader.* = .init(chunks, try server.arena.alloc(u8, 4096));
        var with_type: std.ArrayList(Header) = .empty;
        try with_type.appendSlice(server.arena, headers);
        if (body.text.len > 0 and body.text[0] == '{') try with_type.append(server.arena, .{ .name = "content-type", .value = "application/json" });
        return .{ .status = status, .headers = with_type.items, .body = &reader.reader, .context = reader, .vtable = &.{ .failure = noFailure, .close = noClose } };
    }
};

fn noFailure(_: *anyopaque) http.Error {
    return error.Transport;
}

fn noClose(_: *anyopaque) void {}

/// A channel bound to one stream of the server.
const Bound = struct {
    server: *HttpServer,
    log: *Log,

    fn send(context: *anyopaque, message: []const u8) void {
        const bound: *Bound = @ptrCast(@alignCast(context));
        const log = bound.log;
        const event = std.fmt.allocPrint(bound.server.arena, "id: {s}/{d}\ndata: {s}\n\n", .{ log.id, log.events.items.len, message }) catch return;
        log.events.append(bound.server.arena, event) catch return;
        const parsed = jsonrpc.parseOne(bound.server.arena, message) catch return;
        if (log.request) |id| if (parsed.answers()) |answered| if (answered.eql(id)) {
            log.finished = true;
        };
    }

    fn close(context: *anyopaque) void {
        const bound: *Bound = @ptrCast(@alignCast(context));
        bound.server.reachable = false;
    }
};

/// A connection to a stream, read as it grows: when it has read all there is and the stream goes on, it falls silent
/// for the wait its request gave, on the test's clock.
const Reading = struct {
    server: *HttpServer,
    log: *Log,
    next_event: usize,
    /// Whether the priming event, which opens a first connection, went.
    primed: bool,
    breaks: ?usize,
    /// How long a read waits for what does not come, as its request said.
    idle_ms: ?u64,
    sent: usize = 0,
    pending: []const u8 = "",
    failed: http.Error = error.Transport,
    closed: bool = false,
    reader: std.Io.Reader,

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const reading: *Reading = @fieldParentPtr("reader", r);
        if (reading.pending.len == 0) {
            if (!reading.primed) {
                reading.primed = true;
                reading.pending = std.fmt.allocPrint(reading.server.arena, "id: {s}/-1\nretry: 10\ndata: \n\n", .{reading.log.id}) catch return error.ReadFailed;
            } else if (reading.breaks != null and reading.sent == reading.breaks.?) {
                reading.failed = error.Transport;
                return error.ReadFailed;
            } else if (reading.next_event < reading.log.events.items.len) {
                reading.pending = reading.log.events.items[reading.next_event];
                reading.next_event += 1;
                reading.sent += 1;
            } else if (reading.log.finished) {
                return error.EndOfStream;
            } else {
                // Nothing more comes until a task sends it: the read falls silent, its wait passing on the test's clock.
                if (reading.idle_ms) |ms| reading.server.host.sleep(ms) catch {};
                reading.failed = error.Timeout;
                return error.ReadFailed;
            }
        }
        const bytes = reading.pending[0..limit.minInt(reading.pending.len)];
        try w.writeAll(bytes);
        reading.pending = reading.pending[bytes.len..];
        return bytes.len;
    }

    fn failure(context: *anyopaque) http.Error {
        const reading: *Reading = @ptrCast(@alignCast(context));
        return reading.failed;
    }

    /// A stateless call whose stream is closed before its answer is cancelled.
    fn close(context: *anyopaque) void {
        const reading: *Reading = @ptrCast(@alignCast(context));
        if (reading.closed) return;
        reading.closed = true;
        const id = reading.log.request orelse return;
        if (reading.log.finished or reading.server.fake.session.era != .modern) return;
        reading.server.fake.abort(id) catch {};
    }
};

/// The checks of a stateless request's headers: the version header matches the body, as do `Mcp-Method` and
/// `Mcp-Name`; the refusal as JSON text where one does not.
fn headerRefusal(arena: Allocator, request: http.Request, message: jsonrpc.Message, version: []const u8) Allocator.Error!?[]const u8 {
    const id: ?jsonrpc.Id = switch (message) {
        .request => |given| given.id,
        else => null,
    };
    const mismatch = struct {
        fn of(given_arena: Allocator, given_id: ?jsonrpc.Id, detail: []const u8) Allocator.Error![]const u8 {
            return (jsonrpc.Message{ .failure = .{ .id = given_id, .@"error" = .{ .code = protocol.codes.header_mismatch, .message = try std.fmt.allocPrint(given_arena, "Header mismatch: {s}", .{detail}) } } }).encode(given_arena);
        }
    }.of;
    const given_version = http.find(request.headers, "mcp-protocol-version") orelse "";
    if (!std.mem.eql(u8, given_version, version)) return try mismatch(arena, id, "MCP-Protocol-Version");
    const method, const params = switch (message) {
        .request => |given| .{ given.method, given.params },
        .notification => |given| .{ given.method, given.params },
        else => return null,
    };
    if (!std.mem.eql(u8, http.find(request.headers, "mcp-method") orelse "", method)) return try mismatch(arena, id, "Mcp-Method");
    const key: ?[]const u8 = if (std.mem.eql(u8, method, "tools/call") or std.mem.eql(u8, method, "prompts/get")) "name" else if (std.mem.eql(u8, method, "resources/read")) "uri" else null;
    if (key) |name_key| if (params) |given| if (given.object.get(name_key)) |name| {
        const header = try headers_.decodedValue(arena, http.find(request.headers, "mcp-name") orelse "");
        if (!std.mem.eql(u8, header, name.string)) return try mismatch(arena, id, "Mcp-Name");
    };
    return null;
}

fn modernVersion(message: jsonrpc.Message) ?[]const u8 {
    const params = switch (message) {
        .request => |given| given.params,
        .notification => |given| given.params,
        else => null,
    } orelse return null;
    const meta = params.object.get("_meta") orelse return null;
    if (meta != .object) return null;
    const version = meta.object.get(protocol.meta.protocol_version) orelse return null;
    return if (version == .string) version.string else null;
}

fn copied(arena: Allocator, request: http.Request) Allocator.Error!http.Request {
    const headers = try arena.alloc(Header, request.headers.len);
    for (request.headers, headers) |header, *copy| copy.* = .{ .name = try arena.dupe(u8, header.name), .value = try arena.dupe(u8, header.value) };
    return .{ .method = request.method, .url = try arena.dupe(u8, request.url), .headers = headers, .body = if (request.body) |body| try arena.dupe(u8, body) else null, .wait = request.wait };
}
