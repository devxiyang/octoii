//! The WebSocket a part does by default: the standard library's HTTP client on the host's io opens a socket with the
//! handshake of RFC 6455 and keeps its connection. A task on the io reads the socket's frames into an inbox as they
//! come, answering pings, so that a receive waits as long as it is told to; where the io runs nothing concurrently, a
//! receive reads the next message itself, however long it takes. Writes and the reading of a frame take turns at the
//! connection's lock, as TLS changes its keys for writing on a key update it reads. Any part may be given another
//! `Connector` in its place, as a test gives a replay.
const StdWebSocket = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = @import("http.zig");
const websocket = @import("websocket.zig");

client: std.http.Client,

pub fn init(gpa: Allocator, io: Io) StdWebSocket {
    return .{ .client = .{ .allocator = gpa, .io = io } };
}

/// Lets the client go; every socket it opened is closed first.
pub fn deinit(std_websocket: *StdWebSocket) void {
    std_websocket.client.deinit();
}

pub fn connector(std_websocket: *StdWebSocket) websocket.Connector {
    return .{ .context = std_websocket, .vtable = &.{ .connect = connect } };
}

/// A message read and waiting for a receive, in the client's allocator.
const Arrived = struct { opcode: websocket.Opcode, bytes: []u8 };

/// How the reading of a socket ended: its peer closed it, or it broke off.
const End = enum { closed, broken };

/// An open socket.
const Open = struct {
    owner: *StdWebSocket,
    connection: *std.http.Client.Connection,
    /// Writes, and the reading of a frame, one at a time.
    lock: Io.Mutex = .init,
    assembly: websocket.Assembly = .{},
    /// What the reading task read and no receive has taken, and how its reading ended.
    inbox_lock: Io.Mutex = .init,
    arrived: Io.Condition = .init,
    inbox: std.ArrayList(Arrived) = .empty,
    end: ?End = null,
    reading: ?Io.Future(void) = null,
    /// Whether a close frame went, sent or answered.
    close_sent: bool = false,

    fn gpa(open: *const Open) Allocator {
        return open.owner.client.allocator;
    }

    fn io(open: *const Open) Io {
        return open.owner.client.io;
    }
};

fn connect(context: *anyopaque, opening: websocket.Opening) (websocket.Error || Allocator.Error)!websocket.Socket {
    const std_websocket: *StdWebSocket = @ptrCast(@alignCast(context));
    const gpa = std_websocket.client.allocator;
    const io = std_websocket.client.io;
    const uri = std.Uri.parse(opening.url) catch return error.Transport;
    var random: [16]u8 = undefined;
    io.random(&random);
    const key = websocket.keyOf(random);
    const headers = try gpa.alloc(http.Header, opening.headers.len + 3);
    defer gpa.free(headers);
    @memcpy(headers[0..opening.headers.len], opening.headers);
    headers[opening.headers.len..][0..3].* = .{
        .{ .name = "upgrade", .value = "websocket" },
        .{ .name = "sec-websocket-version", .value = "13" },
        .{ .name = "sec-websocket-key", .value = &key },
    };
    var request = std_websocket.client.request(.GET, uri, .{
        .headers = .{ .connection = .{ .override = "Upgrade" }, .accept_encoding = .omit },
        .extra_headers = headers,
        .redirect_behavior = .not_allowed,
    }) catch |err| return failed(err);
    defer request.deinit();
    request.sendBodiless() catch |err| return failed(err);
    const response = request.receiveHead(&.{}) catch |err| return failed(err);
    if (response.head.status != .switching_protocols or !accepted(response.head, &key)) return error.Transport;
    // The connection speaks WebSocket from here: the request lets it go, and the socket keeps it.
    const connection = request.connection.?;
    request.connection = null;
    const open = gpa.create(Open) catch |err| {
        connection.closing = true;
        std_websocket.client.connection_pool.release(connection, io);
        return err;
    };
    errdefer gpa.destroy(open);
    open.* = .{ .owner = std_websocket, .connection = connection };
    open.reading = io.concurrent(readAll, .{open}) catch null;
    return .{ .context = open, .vtable = &.{ .send = send, .receive = receive, .close = close, .deinit = release } };
}

/// What opening a socket fails as: the host's cancel as `Canceled`, memory as itself, every other failure `Transport`.
fn failed(err: anyerror) (websocket.Error || Allocator.Error) {
    return switch (err) {
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Transport,
    };
}

/// Whether the server's head answers the handshake's `key` as RFC 6455 has it.
fn accepted(head: std.http.Client.Response.Head, key: []const u8) bool {
    const expected = websocket.acceptOf(key);
    var it = head.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-accept")) return std.mem.eql(u8, header.value, &expected);
    }
    return false;
}

fn send(context: *anyopaque, message: websocket.Message) websocket.Error!void {
    const open: *Open = @ptrCast(@alignCast(context));
    open.lock.lock(open.io()) catch return error.Canceled;
    defer open.lock.unlock(open.io());
    switch (message) {
        .text => |text| try writeLocked(open, .text, text),
        .binary => |bytes| try writeLocked(open, .binary, bytes),
    }
}

/// Writes one frame and flushes it; the connection's lock is held.
fn writeLocked(open: *Open, opcode: websocket.Opcode, payload: []const u8) websocket.Error!void {
    var mask: [4]u8 = undefined;
    open.io().random(&mask);
    websocket.writeFrame(open.connection.writer(), opcode, payload, mask) catch return error.Transport;
    open.connection.flush() catch return error.Transport;
}

/// Reads the socket into the inbox until it ends or the task is canceled.
fn readAll(open: *Open) void {
    const end: End = while (true) {
        const message = readMessage(open) catch |err| switch (err) {
            error.Canceled => return,
            error.Closed => break .closed,
            else => break .broken,
        };
        open.inbox_lock.lockUncancelable(open.io());
        defer open.inbox_lock.unlock(open.io());
        open.inbox.append(open.gpa(), message) catch {
            open.gpa().free(message.bytes);
            break .broken;
        };
        open.arrived.signal(open.io());
    };
    endReading(open, end);
}

const ReadError = websocket.ReadFrameError || error{ Canceled, Closed, Transport };

/// The next message whole, the pings before it answered; `Closed` where the peer closes the socket first.
fn readMessage(open: *Open) ReadError!Arrived {
    while (true) {
        try awaitBytes(open);
        open.lock.lock(open.io()) catch return error.Canceled;
        defer open.lock.unlock(open.io());
        const frame = try websocket.readFrame(open.gpa(), open.connection.reader());
        switch (try open.assembly.take(open.gpa(), frame)) {
            .message => |message| return .{ .opcode = message.opcode, .bytes = message.bytes },
            .ping => |payload| {
                defer open.gpa().free(payload);
                try writeLocked(open, .pong, payload);
            },
            .close => {
                if (!open.close_sent) writeLocked(open, .close, &.{}) catch {};
                open.close_sent = true;
                return error.Closed;
            },
            .partial => {},
        }
    }
}

/// Waits, without the lock, until the connection has bytes to read: what TLS decrypted, or what the network brought.
fn awaitBytes(open: *Open) ReadError!void {
    if (open.connection.reader().bufferedLen() > 0) return;
    open.connection.stream_reader.interface.fill(1) catch |err| return switch (err) {
        error.ReadFailed => if (open.connection.stream_reader.err) |cause| (if (cause == error.Canceled) error.Canceled else error.Transport) else error.Transport,
        error.EndOfStream => error.EndOfStream,
    };
}

fn receive(context: *anyopaque, arena: Allocator, wait_ms: ?u64) (websocket.Error || Allocator.Error)!websocket.Received {
    const open: *Open = @ptrCast(@alignCast(context));
    if (open.reading == null) return receiveInline(open, arena);
    const io = open.io();
    open.inbox_lock.lock(io) catch return error.Canceled;
    defer open.inbox_lock.unlock(io);
    const deadline: ?Io.Clock.Timestamp = if (wait_ms) |ms| .fromNow(io, .{ .raw = .fromMilliseconds(@intCast(ms)), .clock = .awake }) else null;
    while (open.inbox.items.len == 0 and open.end == null) {
        if (deadline) |at| {
            open.arrived.waitTimeout(io, &open.inbox_lock, .{ .deadline = at }) catch |err| switch (err) {
                error.Timeout => return if (open.inbox.items.len == 0 and open.end == null) .quiet else continue,
                error.Canceled => return error.Canceled,
            };
        } else open.arrived.wait(io, &open.inbox_lock) catch return error.Canceled;
    }
    if (open.inbox.items.len == 0) return switch (open.end.?) {
        .closed => .closed,
        .broken => error.Transport,
    };
    const arrived = open.inbox.orderedRemove(0);
    defer open.gpa().free(arrived.bytes);
    return messageOf(arena, arrived);
}

/// The next message, read now, where no task reads the socket.
fn receiveInline(open: *Open, arena: Allocator) (websocket.Error || Allocator.Error)!websocket.Received {
    if (open.end) |end| return if (end == .closed) .closed else error.Transport;
    if (open.close_sent) return .closed;
    const arrived = readMessage(open) catch |err| {
        open.end = if (err == error.Closed) .closed else .broken;
        return switch (err) {
            error.Closed => .closed,
            error.Canceled => error.Canceled,
            error.OutOfMemory => error.OutOfMemory,
            else => error.Transport,
        };
    };
    defer open.gpa().free(arrived.bytes);
    return messageOf(arena, arrived);
}

fn messageOf(arena: Allocator, arrived: Arrived) Allocator.Error!websocket.Received {
    const bytes = try arena.dupe(u8, arrived.bytes);
    return .{ .message = if (arrived.opcode == .text) .{ .text = bytes } else .{ .binary = bytes } };
}

fn close(context: *anyopaque) void {
    const open: *Open = @ptrCast(@alignCast(context));
    const io = open.io();
    {
        open.lock.lockUncancelable(io);
        defer open.lock.unlock(io);
        if (!open.close_sent) writeLocked(open, .close, &[_]u8{ 0x03, 0xe8 }) catch {};
        open.close_sent = true;
    }
    endReading(open, .closed);
}

/// Ends what receives get, where nothing ended it before: they take what the inbox holds, then `end`.
fn endReading(open: *Open, end: End) void {
    open.inbox_lock.lockUncancelable(open.io());
    defer open.inbox_lock.unlock(open.io());
    if (open.end == null) open.end = end;
    open.arrived.broadcast(open.io());
}

fn release(context: *anyopaque) void {
    const open: *Open = @ptrCast(@alignCast(context));
    const io = open.io();
    const gpa = open.gpa();
    if (open.reading) |*reading| reading.cancel(io);
    open.connection.closing = true;
    open.owner.client.connection_pool.release(open.connection, io);
    for (open.inbox.items) |arrived| gpa.free(arrived.bytes);
    open.inbox.deinit(gpa);
    open.assembly.deinit(gpa);
    gpa.destroy(open);
}

/// Answers one socket on `server`: the handshake, then each text message echoed in capitals, a ping first; it closes
/// the socket at the message "bye".
fn serveEcho(io: Io, server: *Io.net.Server) void {
    const connection = server.accept(io) catch return;
    defer connection.close(io);
    var in_buffer: [4096]u8 = undefined;
    var out_buffer: [4096]u8 = undefined;
    var reader = connection.reader(io, &in_buffer);
    var writer = connection.writer(io, &out_buffer);
    var http_server: std.http.Server = .init(&reader.interface, &writer.interface);
    var request = http_server.receiveHead() catch return;
    const upgrade = request.upgradeRequested();
    if (upgrade != .websocket) return;
    var socket = request.respondWebSocket(.{ .key = upgrade.websocket.? }) catch return;
    socket.writeMessage("!", .ping) catch return;
    while (true) {
        const message = socket.readSmallMessage() catch return;
        if (message.opcode == .pong) continue;
        if (std.mem.eql(u8, message.data, "bye")) {
            socket.writeMessage(&.{ 0x03, 0xe8 }, .connection_close) catch {};
            return;
        }
        var upper: [128]u8 = undefined;
        socket.writeMessage(std.ascii.upperString(&upper, message.data[0..@min(message.data.len, upper.len)]), .text) catch return;
    }
}

test "a socket opens with the handshake, sends and receives, answers a ping, and ends as its peer closes it" {
    const io = std.testing.io;
    var address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var future = try io.concurrent(serveEcho, .{ io, &server });
    defer future.cancel(io);
    var std_websocket: StdWebSocket = .init(std.testing.allocator, io);
    defer std_websocket.deinit();
    var url_buffer: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "ws://127.0.0.1:{d}/listen", .{server.socket.address.getPort()});
    const socket = try std_websocket.connector().connect(.{ .url = url, .headers = &.{.{ .name = "authorization", .value = "Token t" }} });
    defer socket.deinit();
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    try socket.send(.{ .text = "hello" });
    try std.testing.expectEqualStrings("HELLO", (try socket.receive(arena, 5000)).message.text);
    try socket.send(.{ .text = "bye" });
    try std.testing.expectEqual(.closed, std.meta.activeTag(try socket.receive(arena, 5000)));
}

test "a receive says so where nothing comes within its wait, and ends closed once the socket is closed" {
    const io = std.testing.io;
    var address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var future = try io.concurrent(serveEcho, .{ io, &server });
    defer future.cancel(io);
    var std_websocket: StdWebSocket = .init(std.testing.allocator, io);
    defer std_websocket.deinit();
    var url_buffer: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "ws://127.0.0.1:{d}/", .{server.socket.address.getPort()});
    const socket = try std_websocket.connector().connect(.{ .url = url });
    defer socket.deinit();
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    try std.testing.expectEqual(.quiet, std.meta.activeTag(try socket.receive(arena_allocator.allocator(), 50)));
    socket.close();
    try std.testing.expectEqual(.closed, std.meta.activeTag(try socket.receive(arena_allocator.allocator(), 50)));
}
