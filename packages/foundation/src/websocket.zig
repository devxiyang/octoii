//! WebSocket as the libraries take it: an interface the host implements — the node over its client, a test over a
//! recording — through which a library opens a socket with headers, which a browser's WebSocket cannot send, and sends
//! and receives its messages. A receive waits as long as it is told to and says so where nothing came; a socket is
//! let go by closing it, whoever ended it. Below the interface, what every client shares: the opening handshake's key
//! and the answer it expects, and the frames of RFC 6455.
const std = @import("std");
const Allocator = std.mem.Allocator;
const http = @import("http.zig");

/// A message of a socket: text, or bytes.
pub const Message = union(enum) {
    text: []const u8,
    binary: []const u8,
};

/// Why a socket did not open or broke off: the network failed or its peer refused it, or the host canceled the task.
pub const Error = error{ Transport, Canceled };

/// What a receive came to: a message, the socket closed by its peer, or nothing within the wait.
pub const Received = union(enum) {
    message: Message,
    closed,
    quiet,
};

/// An open socket. Sending, closing and receiving may go on at once, from several tasks, one receiving; what it
/// receives is the caller's. It is let go with `deinit`, once nothing else is called on it.
pub const Socket = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (context: *anyopaque, message: Message) Error!void,
        /// The next message, in `arena`, waiting at most `wait_ms`; none, until one comes or the socket ends.
        receive: *const fn (context: *anyopaque, arena: Allocator, wait_ms: ?u64) (Error || Allocator.Error)!Received,
        /// Closes the socket where it is open: a receive waiting meanwhile, and every one after, ends `closed`.
        close: *const fn (context: *anyopaque) void,
        /// Lets the socket go, closed or not.
        deinit: *const fn (context: *anyopaque) void,
    };

    pub fn send(socket: Socket, message: Message) Error!void {
        return socket.vtable.send(socket.context, message);
    }

    pub fn receive(socket: Socket, arena: Allocator, wait_ms: ?u64) (Error || Allocator.Error)!Received {
        return socket.vtable.receive(socket.context, arena, wait_ms);
    }

    pub fn close(socket: Socket) void {
        socket.vtable.close(socket.context);
    }

    pub fn deinit(socket: Socket) void {
        socket.vtable.deinit(socket.context);
    }
};

/// A socket to open: its `ws` or `wss` address and the headers it opens with.
pub const Opening = struct {
    url: []const u8,
    headers: []const http.Header = &.{},
};

/// The host's WebSocket: one call, which opens a socket.
pub const Connector = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        connect: *const fn (context: *anyopaque, opening: Opening) (Error || Allocator.Error)!Socket,
    };

    pub fn connect(connector: Connector, opening: Opening) (Error || Allocator.Error)!Socket {
        return connector.vtable.connect(connector.context, opening);
    }
};

/// The GUID RFC 6455 joins to a handshake's key.
const handshake_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// A handshake's key: sixteen random bytes, as base64.
pub const Key = [24]u8;

pub fn keyOf(random: [16]u8) Key {
    var key: Key = undefined;
    _ = std.base64.standard.Encoder.encode(&key, &random);
    return key;
}

/// The `Sec-WebSocket-Accept` a server answers `key` with.
pub fn acceptOf(key: []const u8) [28]u8 {
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(key);
    sha1.update(handshake_guid);
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    sha1.final(&digest);
    var accept: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&accept, &digest);
    return accept;
}

/// What a frame carries, by its opcode.
pub const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
    _,

    fn isControl(opcode: Opcode) bool {
        return @backingInt(opcode) >= 8;
    }
};

/// The longest message a socket takes; a longer one breaks it off.
pub const max_message_len = 16 * 1024 * 1024;

/// Writes one frame from the client: final, masked with `mask`, as RFC 6455 has a client's frames.
pub fn writeFrame(writer: *std.Io.Writer, opcode: Opcode, payload: []const u8, mask: [4]u8) std.Io.Writer.Error!void {
    try writer.writeByte(0x80 | @as(u8, @backingInt(opcode)));
    if (payload.len < 126) {
        try writer.writeByte(0x80 | @as(u8, @intCast(payload.len)));
    } else if (payload.len <= std.math.maxInt(u16)) {
        try writer.writeByte(0x80 | 126);
        try writer.writeInt(u16, @intCast(payload.len), .big);
    } else {
        try writer.writeByte(0x80 | 127);
        try writer.writeInt(u64, payload.len, .big);
    }
    try writer.writeAll(&mask);
    var chunk: [512]u8 = undefined;
    var at: usize = 0;
    while (at < payload.len) {
        const len = @min(chunk.len, payload.len - at);
        for (chunk[0..len], payload[at..][0..len], at..) |*out, byte, index| out.* = byte ^ mask[index % 4];
        try writer.writeAll(chunk[0..len]);
        at += len;
    }
}

/// A frame read: its opcode, whether it ends its message, and its payload, unmasked.
pub const Frame = struct {
    opcode: Opcode,
    final: bool,
    payload: []u8,
};

pub const ReadFrameError = std.Io.Reader.Error || Allocator.Error || error{ BadFrame, TooLong };

/// Reads one frame, its payload in `gpa`, unmasked where its sender masked it.
pub fn readFrame(gpa: Allocator, reader: *std.Io.Reader) ReadFrameError!Frame {
    const head = try reader.takeArray(2);
    const opcode: Opcode = @fromBackingInt(@intCast(@as(u4, @truncate(head[0]))));
    const final = head[0] & 0x80 != 0;
    if (head[0] & 0x70 != 0) return error.BadFrame;
    const masked = head[1] & 0x80 != 0;
    const len: u64 = switch (head[1] & 0x7f) {
        126 => try reader.takeInt(u16, .big),
        127 => try reader.takeInt(u64, .big),
        else => |short| short,
    };
    if (opcode.isControl() and (len > 125 or !final)) return error.BadFrame;
    if (len > max_message_len) return error.TooLong;
    const mask: ?[4]u8 = if (masked) (try reader.takeArray(4)).* else null;
    const payload = try gpa.alloc(u8, @intCast(len));
    errdefer gpa.free(payload);
    try reader.readSliceAll(payload);
    if (mask) |key| for (payload, 0..) |*byte, index| {
        byte.* ^= key[index % 4];
    };
    return .{ .opcode = opcode, .final = final, .payload = payload };
}

/// A message being read from its frames, and the frames of control a socket answers between them.
pub const Assembly = struct {
    opcode: ?Opcode = null,
    bytes: std.ArrayList(u8) = .empty,

    pub fn deinit(assembly: *Assembly, gpa: Allocator) void {
        assembly.bytes.deinit(gpa);
    }

    /// What a frame comes to: a message whole, a ping to answer, the peer's close, or nothing yet.
    pub const Step = union(enum) {
        message: struct { opcode: Opcode, bytes: []u8 },
        ping: []u8,
        close,
        partial,
    };

    /// Takes `frame`, which it owns from here.
    pub fn take(assembly: *Assembly, gpa: Allocator, frame: Frame) (Allocator.Error || error{ BadFrame, TooLong })!Step {
        switch (frame.opcode) {
            .ping => return .{ .ping = frame.payload },
            .pong => {
                gpa.free(frame.payload);
                return .partial;
            },
            .close => {
                gpa.free(frame.payload);
                return .close;
            },
            .text, .binary, .continuation => {},
            _ => {
                gpa.free(frame.payload);
                return error.BadFrame;
            },
        }
        defer gpa.free(frame.payload);
        if ((frame.opcode == .continuation) == (assembly.opcode == null)) return error.BadFrame;
        if (assembly.opcode == null) assembly.opcode = frame.opcode;
        if (assembly.bytes.items.len + frame.payload.len > max_message_len) return error.TooLong;
        try assembly.bytes.appendSlice(gpa, frame.payload);
        if (!frame.final) return .partial;
        const opcode = assembly.opcode.?;
        assembly.opcode = null;
        return .{ .message = .{ .opcode = opcode, .bytes = try assembly.bytes.toOwnedSlice(gpa) } };
    }
};

test "a handshake's key is answered as RFC 6455 shows" {
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &acceptOf("dGhlIHNhbXBsZSBub25jZQ=="));
    try std.testing.expectEqualStrings("AAECAwQFBgcICQoLDA0ODw==", &keyOf(.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }));
}

test "a client's frame is masked and reads back, a message whole from its fragments, a ping kept to answer" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeFrame(&out.writer, .text, "Hello", .{ 0x37, 0xfa, 0x21, 0x3d });
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 }, out.written());
    const long = try gpa.alloc(u8, 70_000);
    defer gpa.free(long);
    @memset(long, 'x');
    try writeFrame(&out.writer, .binary, long, .{ 1, 2, 3, 4 });
    var reader: std.Io.Reader = .fixed(out.written());
    const hello = try readFrame(gpa, &reader);
    defer gpa.free(hello.payload);
    try std.testing.expectEqualStrings("Hello", hello.payload);
    const bytes = try readFrame(gpa, &reader);
    defer gpa.free(bytes.payload);
    try std.testing.expectEqualSlices(u8, long, bytes.payload);

    // A server's unmasked frames: "Hel", a ping between, then "lo".
    var server: std.Io.Reader = .fixed(&.{ 0x01, 0x03, 0x48, 0x65, 0x6c, 0x89, 0x01, 0x21, 0x80, 0x02, 0x6c, 0x6f, 0x88, 0x00 });
    var assembly: Assembly = .{};
    defer assembly.deinit(gpa);
    try std.testing.expectEqual(.partial, std.meta.activeTag(try assembly.take(gpa, try readFrame(gpa, &server))));
    const ping = (try assembly.take(gpa, try readFrame(gpa, &server))).ping;
    defer gpa.free(ping);
    try std.testing.expectEqualStrings("!", ping);
    const message = (try assembly.take(gpa, try readFrame(gpa, &server))).message;
    defer gpa.free(message.bytes);
    try std.testing.expectEqual(Opcode.text, message.opcode);
    try std.testing.expectEqualStrings("Hello", message.bytes);
    try std.testing.expectEqual(.close, std.meta.activeTag(try assembly.take(gpa, try readFrame(gpa, &server))));
}

/// Reads a server's message from its fragments with `gpa`, a ping between them, and lets it go.
fn readFragments(gpa: Allocator) !void {
    var server: std.Io.Reader = .fixed(&.{ 0x01, 0x03, 0x48, 0x65, 0x6c, 0x89, 0x01, 0x21, 0x80, 0x02, 0x6c, 0x6f });
    var assembly: Assembly = .{};
    defer assembly.deinit(gpa);
    _ = try assembly.take(gpa, try readFrame(gpa, &server));
    gpa.free((try assembly.take(gpa, try readFrame(gpa, &server))).ping);
    gpa.free((try assembly.take(gpa, try readFrame(gpa, &server))).message.bytes);
}

test "frames read and a message assembled free what they took where an allocation fails on the way" {
    try @import("testing.zig").checkAllAllocationFailures(readFragments, .{});
}

test "frames read and messages assembled take whatever bytes they are given, and free what they took" {
    const fragments = [_]u8{ 0x01, 0x03, 0x48, 0x65, 0x6c, 0x89, 0x01, 0x21, 0x80, 0x02, 0x6c, 0x6f, 0x88, 0x00 };
    try std.testing.fuzz({}, fuzzFrames, .{ .corpus = &.{&fragments} });
}

/// Reads the frames of whatever bytes the fuzzer gives and assembles their messages, till the bytes end or break.
fn fuzzFrames(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var buffer: [4096]u8 = undefined;
    var reader: std.Io.Reader = .fixed(buffer[0..smith.slice(&buffer)]);
    var assembly: Assembly = .{};
    defer assembly.deinit(gpa);
    while (true) {
        const frame = readFrame(gpa, &reader) catch return;
        switch (assembly.take(gpa, frame) catch return) {
            .message => |message| gpa.free(message.bytes),
            .ping => |ping| gpa.free(ping),
            .close => return,
            .partial => {},
        }
    }
}
