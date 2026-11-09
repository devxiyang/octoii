//! A host's HTTP answered from a recording, for tests. Each request is matched, in order, with the next exchange — by
//! its method, its address, the headers the recording names, and its body as JSON, or as bytes where the recording
//! keeps them as `{"base64": ...}` — and answered with the recorded status and headers, its body given one recorded
//! chunk a read, as it arrived. A request the recording does not expect fails as `Transport`, with why in `mismatch`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("json.zig");
const multipart = @import("multipart.zig");
const transport = @import("http.zig");

/// A request and the response it was given, as a recording keeps them.
pub const Exchange = struct {
    request: struct {
        method: []const u8,
        url: []const u8,
        /// The headers a test checks, as a recording holds no credentials; others are not checked.
        headers: ?std.json.ArrayHashMap([]const u8) = null,
        /// The body as JSON, or its bytes as `{"base64": ...}`; none for a request without one.
        body: ?std.json.Value = null,
    },
    response: struct {
        status: u16,
        headers: ?std.json.ArrayHashMap([]const u8) = null,
        chunks: []const Chunk = &.{},
    },
};

/// A chunk of a recorded body: text, or bytes as base64.
pub const Chunk = union(enum) {
    text: []const u8,
    bytes: struct { base64: []const u8 },

    const variants = json.Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};

pub const Replay = struct {
    /// Where everything the replay keeps lives: a test's arena.
    arena: Allocator,
    exchanges: []const Exchange,
    next: usize = 0,
    /// The requests sent, in order, as they were sent.
    sent: std.ArrayList(transport.Request) = .empty,
    /// Why the last request refused was not the one expected.
    mismatch: ?[]const u8 = null,

    pub fn init(arena: Allocator, exchanges: []const Exchange) Replay {
        return .{ .arena = arena, .exchanges = exchanges };
    }

    pub fn http(replay: *Replay) transport.Http {
        return .{ .context = replay, .vtable = &.{ .send = send } };
    }

    /// The exchanges no request has been matched with yet.
    pub fn unused(replay: *const Replay) []const Exchange {
        return replay.exchanges[replay.next..];
    }

    fn send(context: *anyopaque, request: transport.Request) transport.SendError!transport.Response {
        const replay: *Replay = @ptrCast(@alignCast(context));
        try replay.sent.append(replay.arena, try copied(replay.arena, request));
        const number = replay.sent.items.len;
        if (replay.next == replay.exchanges.len) {
            return replay.refuse("request {d}, {t} {s}, comes after the recording's last", .{ number, request.method, request.url });
        }
        const exchange = replay.exchanges[replay.next];
        replay.next += 1;
        if (try mismatchOf(replay.arena, exchange.request, request)) |why| return replay.refuse("request {d}: {s}", .{ number, why });
        return replay.respond(exchange);
    }

    fn refuse(replay: *Replay, comptime format: []const u8, arguments: anytype) transport.SendError {
        replay.mismatch = try replay.arena.print(format, arguments);
        return error.Transport;
    }

    fn respond(replay: *Replay, exchange: Exchange) Allocator.Error!transport.Response {
        const recorded = exchange.response;
        const chunks = try replay.arena.alloc([]const u8, recorded.chunks.len);
        for (recorded.chunks, chunks) |chunk, *bytes| bytes.* = switch (chunk) {
            .text => |text| text,
            .bytes => |kept| try decoded(replay.arena, kept.base64),
        };
        const body = try replay.arena.create(ChunkReader);
        body.* = .init(chunks, try replay.arena.alloc(u8, 4096));
        return .{
            .status = recorded.status,
            .headers = try headersOf(replay.arena, recorded.headers),
            .body = &body.reader,
            .context = body,
            .vtable = &.{ .failure = ChunkReader.failure, .close = ChunkReader.close },
        };
    }
};

/// A reader that gives its chunks one read at a time, as a body streams.
pub const ChunkReader = struct {
    chunks: []const []const u8,
    index: usize = 0,
    offset: usize = 0,
    reader: std.Io.Reader,

    pub fn init(chunks: []const []const u8, buffer: []u8) ChunkReader {
        return .{ .chunks = chunks, .reader = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 } };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const chunks: *ChunkReader = @fieldParentPtr("reader", r);
        if (chunks.index == chunks.chunks.len) return error.EndOfStream;
        const chunk = chunks.chunks[chunks.index];
        const rest = chunk[chunks.offset..];
        const bytes = rest[0..limit.minInt(rest.len)];
        try w.writeAll(bytes);
        chunks.offset += bytes.len;
        if (chunks.offset == chunk.len) {
            chunks.index += 1;
            chunks.offset = 0;
        }
        return bytes.len;
    }

    fn failure(_: *anyopaque) transport.Error {
        // A recorded body never breaks off.
        return error.Transport;
    }

    fn close(_: *anyopaque) void {}
};

/// How the request sent differs from the one recorded; null where it is the same.
fn mismatchOf(arena: Allocator, recorded: @FieldType(Exchange, "request"), sent: transport.Request) Allocator.Error!?[]const u8 {
    if (!std.ascii.eqlIgnoreCase(recorded.method, @tagName(sent.method)) or !std.mem.eql(u8, recorded.url, sent.url)) {
        return try arena.print("{t} {s} was sent where {s} {s} was recorded", .{ sent.method, sent.url, recorded.method, recorded.url });
    }
    if (recorded.headers) |headers| {
        var it = headers.map.iterator();
        while (it.next()) |header| {
            const value = transport.find(sent.headers, header.key_ptr.*);
            if (value == null or !std.mem.eql(u8, value.?, header.value_ptr.*)) {
                return try arena.print("the header {s} was {?s} where {s} was recorded", .{ header.key_ptr.*, value, header.value_ptr.* });
            }
        }
    }
    return bodyMismatch(arena, recorded.body, sent);
}

/// How a body sent differs from the one recorded; null where it is the same.
fn bodyMismatch(arena: Allocator, recorded: ?std.json.Value, request: transport.Request) Allocator.Error!?[]const u8 {
    const sent = request.body;
    const expected = recorded orelse {
        if (sent) |bytes| return try arena.print("a body was sent where none was recorded: {s}", .{bytes});
        return null;
    };
    const shown = try json.encode(arena, expected);
    const bytes = sent orelse return try arena.print("no body was sent where {s} was recorded", .{shown});
    if (base64Of(expected)) |kept| {
        if (std.mem.eql(u8, try decoded(arena, kept), bytes)) return null;
        return "the body's bytes were not those recorded";
    }
    if (formOf(expected)) |fields| {
        const form = try sentForm(arena, request) orelse return try arena.print("no multipart form was sent where {s} was recorded", .{shown});
        if (json.equal(form, fields)) return null;
        return try arena.print("the form {s} was sent where {s} was recorded", .{ try json.encode(arena, form), try json.encode(arena, fields) });
    }
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch null;
    if (value != null and json.equal(value.?, expected)) return null;
    return try arena.print("the body {s} was sent where {s} was recorded", .{ bytes, shown });
}

/// The fields of a body recorded as a multipart form, `{"multipart": [...]}`; null for any other body.
fn formOf(body: std.json.Value) ?std.json.Value {
    if (body != .object or body.object.count() != 1) return null;
    const fields = body.object.get("multipart") orelse return null;
    return if (fields == .array) fields else null;
}

/// The multipart form `request` sent, its fields as a recording writes them: a text field's value, a file's name, type
/// and bytes as base64; null where it sent no form.
fn sentForm(arena: Allocator, request: transport.Request) Allocator.Error!?std.json.Value {
    const content_type = transport.find(request.headers, "content-type") orelse return null;
    const fields = try multipart.parse(arena, content_type, request.body orelse return null) orelse return null;
    var list = std.json.Array.init(arena);
    for (fields) |field| {
        var made: std.json.ObjectMap = .empty;
        try made.put(arena, "name", .{ .string = field.name });
        if (field.value) |value| try made.put(arena, "value", .{ .string = value });
        if (field.filename) |filename| try made.put(arena, "filename", .{ .string = filename });
        if (field.content_type) |content_type_| try made.put(arena, "content_type", .{ .string = content_type_ });
        if (field.data) |data| {
            const encoder = std.base64.standard.Encoder;
            const out = try arena.alloc(u8, encoder.calcSize(data.len));
            try made.put(arena, "base64", .{ .string = encoder.encode(out, data) });
        }
        try list.append(.{ .object = made });
    }
    return .{ .array = list };
}

/// The base64 of a body recorded as bytes, `{"base64": ...}` and nothing else; null for a JSON body.
fn base64Of(body: std.json.Value) ?[]const u8 {
    if (body != .object or body.object.count() != 1) return null;
    const kept = body.object.get("base64") orelse return null;
    return if (kept == .string) kept.string else null;
}

fn decoded(arena: Allocator, base64: []const u8) Allocator.Error![]const u8 {
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(base64) catch return base64;
    const bytes = try arena.alloc(u8, size);
    decoder.decode(bytes, base64) catch return base64;
    return bytes;
}

fn headersOf(arena: Allocator, recorded: ?std.json.ArrayHashMap([]const u8)) Allocator.Error![]const transport.Header {
    const headers = recorded orelse return &.{};
    const out = try arena.alloc(transport.Header, headers.map.count());
    for (headers.map.keys(), headers.map.values(), out) |name, value, *header| header.* = .{ .name = name, .value = value };
    return out;
}

fn copied(arena: Allocator, request: transport.Request) Allocator.Error!transport.Request {
    const headers = try arena.alloc(transport.Header, request.headers.len);
    for (request.headers, headers) |header, *copy| copy.* = .{ .name = try arena.dupe(u8, header.name), .value = try arena.dupe(u8, header.value) };
    return .{
        .method = request.method,
        .url = try arena.dupe(u8, request.url),
        .headers = headers,
        .body = if (request.body) |body| try arena.dupe(u8, body) else null,
    };
}

test "a request as recorded is answered with the recorded response, a chunk a read" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const exchanges = try json.decode([]const Exchange, arena,
        \\[{"request":{"method":"POST","url":"https://api.example/v1","headers":{"x-version":"1"},"body":{"b":[1],"a":true}},
        \\  "response":{"status":200,"headers":{"content-type":"text/plain"},"chunks":["he",{"base64":"bGxv"}]}}]
    );
    var replay: Replay = .init(arena, exchanges);
    const response = try replay.http().send(.{
        .method = .POST,
        .url = "https://api.example/v1",
        .headers = &.{.{ .name = "X-Version", .value = "1" }},
        .body = "{\"a\":true,\"b\":[1.0]}",
    });
    defer response.close();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("text/plain", response.header("Content-Type").?);
    try response.body.fillMore();
    try std.testing.expectEqualStrings("he", response.body.buffered());
    try std.testing.expectEqualStrings("hello", try response.body.allocRemaining(arena, .unlimited));
    try std.testing.expectEqual(@as(usize, 0), replay.unused().len);
    try std.testing.expectEqualStrings("https://api.example/v1", replay.sent.items[0].url);
}

test "a request the recording does not expect is refused, saying why" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const exchanges = try json.decode([]const Exchange, arena,
        \\[{"request":{"method":"POST","url":"https://api.example/v1","body":{"a":1}},"response":{"status":200}}]
    );
    var replay: Replay = .init(arena, exchanges);
    try std.testing.expectError(error.Transport, replay.http().send(.{ .method = .POST, .url = "https://api.example/v1", .body = "{\"a\":2}" }));
    try std.testing.expectEqualStrings("request 1: the body {\"a\":2} was sent where {\"a\":1} was recorded", replay.mismatch.?);
    try std.testing.expectError(error.Transport, replay.http().send(.{ .url = "https://api.example/v2" }));
    try std.testing.expectEqualStrings("request 2, GET https://api.example/v2, comes after the recording's last", replay.mismatch.?);
}
