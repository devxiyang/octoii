//! The HTTP a part does by default: the standard library's client on the host's io, kept alive across requests, its
//! bodies streamed and decompressed. A request's wait is kept by racing each read against the io's clock, the read
//! canceled where the clock wins; a task the host cancels ends its read `Canceled`. Any part may be given another
//! `Http` in its place, as a test gives a replay.
const StdHttp = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const transport = @import("http.zig");

client: std.http.Client,

pub fn init(gpa: Allocator, io: Io) StdHttp {
    return .{ .client = .{ .allocator = gpa, .io = io } };
}

pub fn deinit(std_http: *StdHttp) void {
    std_http.client.deinit();
}

pub fn http(std_http: *StdHttp) transport.Http {
    return .{ .context = std_http, .vtable = &.{ .send = send } };
}

/// One request and its response, alive until the response is closed.
const Exchange = struct {
    arena: std.heap.ArenaAllocator,
    io: Io,
    request: std.http.Client.Request,
    response: std.http.Client.Response,
    inner: *Io.Reader,
    reader: Io.Reader,
    decompress: std.http.Decompress,
    transfer: [8192]u8,
    idle_ms: ?u64,
    failed: transport.Error = error.Transport,
};

fn send(context: *anyopaque, request: transport.Request) transport.SendError!transport.Response {
    const std_http: *StdHttp = @ptrCast(@alignCast(context));
    const gpa = std_http.client.allocator;
    const io = std_http.client.io;
    const exchange = try gpa.create(Exchange);
    exchange.arena = .init(gpa);
    exchange.io = io;
    exchange.idle_ms = if (request.wait) |wait| wait.idle_ms else null;
    exchange.failed = error.Transport;
    errdefer {
        exchange.arena.deinit();
        gpa.destroy(exchange);
    }
    const arena = exchange.arena.allocator();
    const uri = std.Uri.parse(request.url) catch return error.Transport;
    exchange.request = std_http.client.request(request.method, uri, .{
        .extra_headers = try arena.dupe(transport.Header, request.headers),
        .redirect_behavior = if (request.body == null) @fromBackingInt(@intCast(3)) else .unhandled,
    }) catch |err| return sent(err);
    errdefer exchange.request.deinit();
    if (request.body) |body| {
        exchange.request.transfer_encoding = .{ .content_length = body.len };
        var writer = exchange.request.sendBodyUnflushed(&.{}) catch |err| return sent(err);
        writer.writer.writeAll(body) catch return error.Transport;
        writer.end() catch return error.Transport;
        exchange.request.connection.?.flush() catch return error.Transport;
    } else exchange.request.sendBodiless() catch |err| return sent(err);
    const redirects = try arena.alloc(u8, 8 * 1024);
    exchange.response = try waited(transport.SendError, std.http.Client.Response, io, if (request.wait) |wait| wait.head_ms else null, receiveHead, .{ &exchange.request, redirects });
    // The head's strings are good until the body is read: they are copied first.
    var headers: std.ArrayList(transport.Header) = .empty;
    var it = exchange.response.head.iterateHeaders();
    while (it.next()) |header| try headers.append(arena, .{ .name = try arena.dupe(u8, header.name), .value = try arena.dupe(u8, header.value) });
    const window: []u8 = switch (exchange.response.head.content_encoding) {
        .identity => &.{},
        .zstd => try arena.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try arena.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.Transport,
    };
    exchange.inner = exchange.response.readerDecompressing(&exchange.transfer, &exchange.decompress, window);
    exchange.reader = .{ .vtable = &.{ .stream = stream }, .buffer = try arena.alloc(u8, 16 * 1024), .seek = 0, .end = 0 };
    return .{
        .status = @backingInt(exchange.response.head.status),
        .headers = headers.items,
        .body = &exchange.reader,
        .context = exchange,
        .vtable = &.{ .failure = failure, .close = close },
    };
}

/// What sending fails as: the host's cancel as `Canceled`, memory as itself, and every other failure as `Transport`.
fn sent(err: anyerror) transport.SendError {
    return switch (err) {
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Transport,
    };
}

fn receiveHead(request: *std.http.Client.Request, redirects: []u8) transport.SendError!std.http.Client.Response {
    return request.receiveHead(redirects) catch |err| sent(err);
}

/// `function` called with `arguments`, raced against the io's clock where `wait_ms` bounds it: `Timeout` where the
/// clock wins, the call canceled. Where the io runs nothing concurrently, the call is made as it is.
fn waited(comptime E: type, comptime Result: type, io: Io, wait_ms: ?u64, comptime function: anytype, arguments: anytype) (E || error{ Timeout, Canceled })!Result {
    const ms = wait_ms orelse return @call(.auto, function, arguments);
    const Outcome = union(enum) { done: E!Result, slept: Io.Cancelable!void };
    var buffer: [2]Outcome = undefined;
    var select: Io.Select(Outcome) = .init(io, &buffer);
    select.concurrent(.done, function, arguments) catch return @call(.auto, function, arguments);
    select.concurrent(.slept, sleep, .{ io, ms }) catch {
        const outcome = select.await() catch {
            _ = select.cancel();
            return error.Canceled;
        };
        return outcome.done;
    };
    const first = select.await() catch {
        _ = select.cancel();
        return error.Canceled;
    };
    const rest = select.cancel();
    return switch (first) {
        .done => |result| result,
        .slept => {
            // The call may have ended as the clock did: what it made is kept; a call the cancel ended, the wait ran out.
            if (rest) |late| if (late == .done) {
                if (late.done) |result| return result else |_| {}
            };
            return error.Timeout;
        },
    };
}

fn sleep(io: Io, ms: u64) Io.Cancelable!void {
    return io.sleep(.fromMilliseconds(@intCast(ms)), .awake);
}

fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    const exchange: *Exchange = @fieldParentPtr("reader", r);
    return waited(InnerError, usize, exchange.io, exchange.idle_ms, innerStream, .{ exchange, w, limit }) catch |err| switch (err) {
        error.EndOfStream => error.EndOfStream,
        error.WriteFailed => error.WriteFailed,
        error.Timeout, error.Canceled, error.Transport => {
            exchange.failed = switch (err) {
                error.Timeout => error.Timeout,
                error.Canceled => error.Canceled,
                else => error.Transport,
            };
            return error.ReadFailed;
        },
        error.OutOfMemory => error.ReadFailed,
    };
}

const InnerError = transport.SendError || error{ EndOfStream, WriteFailed };

fn innerStream(exchange: *Exchange, w: *Io.Writer, limit: Io.Limit) InnerError!usize {
    return exchange.inner.stream(w, limit) catch |err| switch (err) {
        error.EndOfStream => error.EndOfStream,
        error.WriteFailed => error.WriteFailed,
        error.ReadFailed => error.Transport,
    };
}

fn failure(context: *anyopaque) transport.Error {
    const exchange: *Exchange = @ptrCast(@alignCast(context));
    return exchange.failed;
}

fn close(context: *anyopaque) void {
    const exchange: *Exchange = @ptrCast(@alignCast(context));
    exchange.request.deinit();
    const gpa = exchange.arena.child_allocator;
    exchange.arena.deinit();
    gpa.destroy(exchange);
}

/// Answers one request on `server` with `status` and a body of `chunks`, each sent apart; or, for none, never answers.
fn serve(io: Io, server: *Io.net.Server, chunks: ?[]const []const u8) void {
    const connection = server.accept(io) catch return;
    defer connection.close(io);
    var in_buffer: [4096]u8 = undefined;
    var out_buffer: [4096]u8 = undefined;
    var reader = connection.reader(io, &in_buffer);
    var writer = connection.writer(io, &out_buffer);
    var http_server: std.http.Server = .init(&reader.interface, &writer.interface);
    var request = http_server.receiveHead() catch return;
    const body = chunks orelse {
        io.sleep(.fromSeconds(5), .awake) catch {};
        return;
    };
    var send_buffer: [256]u8 = undefined;
    var out = request.respondStreaming(&send_buffer, .{ .respond_options = .{ .extra_headers = &.{.{ .name = "content-type", .value = "text/event-stream" }} } }) catch return;
    for (body) |chunk| {
        out.writer.writeAll(chunk) catch return;
        out.flush() catch return;
    }
    out.end() catch return;
}

test "a request goes over the network and its body streams back" {
    const io = std.testing.io;
    var address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var future = try io.concurrent(serve, .{ io, &server, &.{ "data: one\n\n", "data: two\n\n" } });
    defer future.cancel(io);
    var std_http: StdHttp = .init(std.testing.allocator, io);
    defer std_http.deinit();
    var url_buffer: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/events", .{server.socket.address.getPort()});
    const response = try std_http.http().send(.{ .method = .POST, .url = url, .body = "{}", .wait = .{ .head_ms = 5000, .idle_ms = 5000 } });
    defer response.close();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("text/event-stream", response.header("Content-Type").?);
    const body = try response.body.allocRemaining(std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("data: one\n\ndata: two\n\n", body);
}

test "a head that does not come within its wait ends the request as a timeout" {
    const io = std.testing.io;
    var address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var future = try io.concurrent(serve, .{ io, &server, null });
    defer future.cancel(io);
    var std_http: StdHttp = .init(std.testing.allocator, io);
    defer std_http.deinit();
    var url_buffer: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/", .{server.socket.address.getPort()});
    try std.testing.expectError(error.Timeout, std_http.http().send(.{ .url = url, .wait = .{ .head_ms = 100, .idle_ms = 100 } }));
}
