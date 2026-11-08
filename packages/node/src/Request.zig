//! A client's request, as the node answers it over either way its clients reach it — HTTP/1.1 on the loopback address,
//! or HTTP/3 in a device's tunnel session: its method, target and fields, its body, and its answer, a response whole or
//! the protocol's WebSocket, which is the standard library's on both. A request is answered once, then let go.
const Request = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http3 = @import("tunnel").http3;

over: Over,

/// The way the request came.
pub const Over = union(enum) {
    /// On the loopback address: the request, and the connection it came on, which its WebSocket takes over.
    loopback: Loopback,
    /// In a device's tunnel session: the request on its stream, and the messages of the WebSocket it opens, read into
    /// memory of `gpa`'s.
    tunnel: Tunneled,
};

pub const Loopback = struct {
    request: *std.http.Server.Request,
    stream: Io.net.Stream,
    io: Io,
};

pub const Tunneled = struct {
    request: *http3.Server.Request,
    /// The key of the device whose session the request came in, as text.
    device: []const u8,
    gpa: Allocator,
    messages: []u8 = &.{},
};

/// How large a message a client's WebSocket may send in a tunnel session; on the loopback, its connection's buffer.
pub const message_bytes_max = 1 << 20;

/// Lets the request go, and what its WebSocket's messages were read into.
pub fn deinit(request: *Request) void {
    switch (request.over) {
        .loopback => {},
        .tunnel => |tunneled| {
            tunneled.gpa.free(tunneled.messages);
            tunneled.request.deinit();
        },
    }
}

pub fn method(request: *const Request) std.http.Method {
    return switch (request.over) {
        .loopback => |loopback| loopback.request.head.method,
        .tunnel => |tunneled| tunneled.request.head.method,
    };
}

/// The request's target: its path and its query.
pub fn target(request: *const Request) []const u8 {
    return switch (request.over) {
        .loopback => |loopback| loopback.request.head.target,
        .tunnel => |tunneled| tunneled.request.head.target,
    };
}

/// The request's path: its target without its query.
pub fn path(request: *const Request) []const u8 {
    const whole = request.target();
    return whole[0 .. std.mem.indexOfAny(u8, whole, "?#") orelse whole.len];
}

/// The request's fields, one by one.
pub fn iterateHeaders(request: *const Request) Fields {
    return switch (request.over) {
        .loopback => |loopback| .{ .loopback = loopback.request.iterateHeaders() },
        .tunnel => |tunneled| .{ .tunnel = tunneled.request.iterateHeaders() },
    };
}

pub const Fields = union(enum) {
    loopback: std.http.HeaderIterator,
    tunnel: http3.message.Fields,

    pub fn next(fields: *Fields) ?std.http.Header {
        return switch (fields.*) {
            inline else => |*each| each.next(),
        };
    }
};

/// A reader of the request's body, read through `buffer`; on the loopback, a client waiting to be told to send it is
/// told.
pub fn reader(request: *Request, buffer: []u8) !*Io.Reader {
    return switch (request.over) {
        .loopback => |loopback| loopback.request.readerExpectContinue(buffer),
        .tunnel => |tunneled| tunneled.request.reader(buffer),
    };
}

/// How a response is sent: its status, and its fields.
pub const Response = struct {
    status: std.http.Status = .ok,
    extra_headers: []const std.http.Header = &.{},
};

/// Answers the request with `body` whole; on the loopback, the connection closed after it, as each request comes on a
/// connection of its own.
pub fn respond(request: *Request, body: []const u8, response: Response) !void {
    switch (request.over) {
        .loopback => |loopback| try loopback.request.respond(body, .{ .status = response.status, .keep_alive = false, .extra_headers = response.extra_headers }),
        .tunnel => |tunneled| try tunneled.request.respond(body, .{ .status = response.status, .extra_headers = response.extra_headers }),
    }
}

/// Whether the request asks for a WebSocket: by HTTP/1.1's upgrade on the loopback, by HTTP/3's extended CONNECT in a
/// tunnel session.
pub fn webSocketRequested(request: *const Request) bool {
    return switch (request.over) {
        .loopback => |loopback| switch (loopback.request.upgradeRequested()) {
            .websocket => |key| key != null,
            .none, .other => false,
        },
        .tunnel => |tunneled| tunneled.request.webSocketRequested(),
    };
}

/// Opens the WebSocket the request asks for: its acceptance sent, the socket on the request's connection or stream
/// from then on, till it is hung up.
pub fn respondWebSocket(request: *Request) !std.http.Server.WebSocket {
    switch (request.over) {
        .loopback => |loopback| {
            const key = loopback.request.upgradeRequested().websocket.?;
            var socket = try loopback.request.respondWebSocket(.{ .key = key });
            try socket.output.flush();
            return socket;
        },
        .tunnel => |*tunneled| {
            tunneled.messages = try tunneled.gpa.alloc(u8, message_bytes_max);
            return tunneled.request.respondWebSocket(.{ .buffer = tunneled.messages });
        },
    }
}

/// Ends both ways of the request's connection or stream, as a socket is shut down both ways: a read waiting on its
/// WebSocket finds its end.
pub fn hangUp(request: *Request) void {
    switch (request.over) {
        .loopback => |loopback| loopback.stream.shutdown(loopback.io, .both) catch {},
        .tunnel => |tunneled| tunneled.request.hangUp(),
    }
}
