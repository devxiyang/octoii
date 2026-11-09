//! `octoii serve`: Siphon's loop run on this computer, and its protocol served to clients — a WebSocket at `/ws`, each
//! client authenticated as it connects by the session it holds — over either way clients reach the node: HTTP/1.1 on
//! the loopback address, a browser holding its session in its cookie, a program as a bearer token; and HTTP/3 in the
//! tunnel sessions of devices, each known by its key. Beside the protocol: the web app's files, where the node is given
//! them, the files a message gives its model, and the one request a client pairs by.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const siphon_ = @import("siphon");
const Siphon = siphon_.Siphon;
const Connection_ = siphon_.protocol.Connection;
const Principal = siphon_.protocol.Access.Principal;
const tunnel = @import("tunnel");
const Station = tunnel.Station;
const Connection = tunnel.Connection;
const http3 = tunnel.http3;
const App = @import("App.zig");
const Access = @import("Access.zig");
const auth = @import("auth.zig");
const files = @import("files.zig");
const Request = @import("Request.zig");

const log = std.log.scoped(.node);

/// The port clients reach the node at unless the person names one.
pub const default_port = 7600;

/// How large a message a client on the loopback may send: its WebSocket's input buffer.
const message_bytes_max = Request.message_bytes_max;

/// Where the protocol's WebSocket is.
pub const socket_path = "/ws";
/// How long serving waits, once the system ran out of what taking a connection needs, before it takes the next.
const accept_retry_ms = 100;

/// What serving a client takes: Siphon, the allocator a client's buffers live on, the access that authenticates
/// clients and pairs browsers, the app's files where there are any, and the name of the cookie a browser holds its
/// session in.
pub const Server = struct {
    siphon: *Siphon,
    gpa: Allocator,
    access: Access,
    app: ?App,
    cookie: []const u8,
};

/// Serves clients on the loopback address at `port`, as `server` says how, until the node is ended.
pub fn serve(server: *const Server, port: u16) !void {
    const io = server.siphon.runtime.host.io;
    var listener = try listen(port);
    defer listener.deinit(io);
    var clients: Io.Group = .init;
    defer clients.cancel(io);
    while (true) {
        const stream = try accepted(&listener, io) orelse continue;
        clients.concurrent(io, serveClient, .{ server, stream }) catch stream.close(io);
    }
}

/// The next connection the listener takes; null for one lost alone — aborted by its peer before it was taken — or for a
/// failure of the system's, logged and waited out a while, as a server's accept loop takes them: a cancel, or the
/// listener's end, alone ends serving.
fn accepted(listener: *Io.net.Server, io: Io) !?Io.net.Stream {
    return listener.accept(io) catch |err| switch (err) {
        error.Canceled, error.SocketNotListening => return err,
        error.ConnectionAborted, error.ProtocolFailure, error.BlockedByFirewall, error.WouldBlock => null,
        else => {
            log.warn("a client's connection could not be taken: {s}", .{@errorName(err)});
            try io.sleep(.fromMilliseconds(accept_retry_ms), .awake);
            return null;
        },
    };
}

/// Listens on the loopback address at `port`, as a server that may start again at once listens: its address taken though
/// the connections of the one before it wait out TIME_WAIT, by SO_REUSEADDR — and never shared with a server listening
/// there already, as SO_REUSEPORT would share it, which the standard library's listen sets with it.
fn listen(port: u16) !Io.net.Server {
    const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = std.c.close(fd);
    if (std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) != 0) return error.SocketFailed;
    const on: c_int = 1;
    if (std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &on, @sizeOf(c_int)) != 0) return error.SocketFailed;
    const loopback: std.c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f00_0001) };
    if (std.c.bind(fd, @ptrCast(&loopback), @sizeOf(std.c.sockaddr.in)) != 0) return error.AddressInUse;
    if (std.c.listen(fd, 128) != 0) return error.ListenFailed;
    return .{ .socket = .{ .handle = fd, .address = .{ .ip4 = .loopback(port) } }, .options = {} };
}

/// One client on the loopback: one request answered on its connection — the protocol, where it asks for the
/// WebSocket, which then takes the connection over — and the connection closed after it: the node speaks over its
/// WebSocket, and plain HTTP only hands a browser the app's files as its page loads, its session as it pairs, and the
/// bytes of files, which JSON carries badly.
fn serveClient(server: *const Server, stream: Io.net.Stream) void {
    const io = server.siphon.runtime.host.io;
    defer stream.close(io);
    const read_buffer = server.gpa.alloc(u8, message_bytes_max) catch return;
    defer server.gpa.free(read_buffer);
    var write_buffer: [16 << 10]u8 = undefined;
    var reader = stream.reader(io, read_buffer);
    var writer = stream.writer(io, &write_buffer);
    var http: std.http.Server = .init(&reader.interface, &writer.interface);
    var head = http.receiveHead() catch return;
    var request: Request = .{ .over = .{ .loopback = .{ .request = &head, .stream = stream, .io = io } } };
    answer(server, &request);
}

/// Serves the devices whose tunnel sessions reach the node through `station`, each session in a task of its own, until
/// the node is ended.
pub fn serveTunnel(server: *const Server, station: *Station) !void {
    const io = server.siphon.runtime.host.io;
    var sessions: Io.Group = .init;
    defer sessions.cancel(io);
    while (true) {
        const connection = try station.accept();
        sessions.concurrent(io, serveSession, .{ server, station, connection }) catch station.close(connection, @backingInt(http3.Code.internal_error));
    }
}

/// One device's tunnel session: its requests, each answered in a task of its own, until the session ends.
fn serveSession(server: *const Server, station: *Station, connection: *Connection) void {
    const io = server.siphon.runtime.host.io;
    defer station.close(connection, @backingInt(http3.Code.no_error));
    const session = http3.Server.init(server.gpa, station, connection) catch return;
    defer session.deinit();
    const device = connection.peer.text();
    var requests: Io.Group = .init;
    defer requests.cancel(io);
    while (true) {
        const taken = session.accept() catch return;
        requests.concurrent(io, serveTunneled, .{ server, taken, &device }) catch taken.deinit();
    }
}

/// One request in a device's tunnel session, answered once its head has come.
fn serveTunneled(server: *const Server, taken: *http3.Server.Request, device: []const u8) void {
    var request: Request = .{ .over = .{ .tunnel = .{ .request = taken, .device = device, .gpa = server.gpa } } };
    defer request.deinit();
    taken.receiveHead() catch return;
    answer(server, &request);
}

/// Answers a request, whichever way it came, as its client is: a browser paired, a file a message gives its model kept
/// or given back, the protocol's WebSocket, or a file of the app's.
fn answer(server: *const Server, request: *Request) void {
    const io = server.siphon.runtime.host.io;
    var arena_allocator: std.heap.ArenaAllocator = .init(server.gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const client = auth.clientOf(arena, request, server.access, server.cookie) catch return;
    const path = request.path();
    if (std.mem.eql(u8, path, socket_path)) return serveSocket(server, request, client);
    const answered = if (std.mem.eql(u8, path, auth.session_path))
        auth.answerSession(arena, request, server.access, client, server.cookie)
    else if (files.isFiles(path))
        files.answer(server.siphon, client, arena, request, path)
    else if (server.app) |app|
        app.respond(io, server.gpa, request)
    else
        App.notFound(request);
    answered catch |err| log.err("a request could not be answered: {s}", .{@errorName(err)});
}

/// The protocol, on the WebSocket the client asks for: opened for the session it holds, or for none, which `hello` then
/// refuses; refused outright to a page of another origin, as a browser may open a socket to any address for any page.
fn serveSocket(server: *const Server, request: *Request, client: auth.Client) void {
    if (!request.webSocketRequested()) return App.notFound(request) catch {};
    if (!client.same_origin) return request.respond("", .{ .status = .forbidden }) catch {};
    serveProtocol(server.siphon, client.principal, request);
}

/// The protocol, on the WebSocket `request` asks for, for `principal`: a connection opened for it among Siphon's
/// clients, what it sends delivered as it comes, and what it is sent written by a task of its own from the
/// connection's outbox.
fn serveProtocol(siphon: *Siphon, principal: ?Principal, request: *Request) void {
    const io = siphon.runtime.host.io;
    var socket = request.respondWebSocket() catch return;
    const connection = siphon.clients.open(principal) catch return;
    var sender = io.concurrent(send, .{ connection, &socket, request }) catch {
        connection.hangUp();
        connection.release();
        return;
    };
    receive(connection, &socket);
    // Hung up, the loop closes the outbox, and the sender ends with what was left; then the host lets go.
    connection.hangUp();
    sender.await(io);
    connection.release();
}

/// Delivers each message the client sends to its connection, till the client is gone.
fn receive(connection: *Connection_, socket: *std.http.Server.WebSocket) void {
    while (true) {
        const message = socket.readSmallMessage() catch return;
        if (message.opcode != .text) continue;
        connection.deliver(message.data) catch return;
    }
}

/// Writes the client what its connection's outbox holds, as it comes, till the client is gone or the outbox is closed —
/// Siphon let it go, or it left — when the WebSocket is closed and the request hung up, so its reader ends too.
fn send(connection: *Connection_, socket: *std.http.Server.WebSocket, request: *Request) void {
    defer request.hangUp();
    var batch: [16][]u8 = undefined;
    while (true) {
        const count = connection.take(&batch, 1) catch {
            socket.writeMessage("", .connection_close) catch {};
            return;
        };
        const taken = batch[0..count];
        defer for (taken) |message| connection.allocator.free(message);
        for (taken) |message| socket.writeMessage(message, .text) catch |err| {
            log.err("a client could not be written to: {s}", .{@errorName(err)});
            return;
        };
    }
}
