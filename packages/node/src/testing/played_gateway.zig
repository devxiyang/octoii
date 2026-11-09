//! A played agent gateway, for the node's tests: it talks on the descriptors 3 and 4 as the gateway does, each start
//! written down in its state folder, and answers each `http` request by its path — its head, 200 as an event stream,
//! then its method and path, and its headers and body, back as two pieces of its body, and its result; at `/hang`, its
//! head and a piece, then nothing more, a `notifications/cancelled` written down; at `/exit`, its head, then its end,
//! with 3. Its input's end ends it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3 or !std.mem.eql(u8, args[1], "--state")) return error.NoState;
    const state = args[2];
    try writeDown(init.io, arena, state, "starts", "started\n");
    var input_buffer: [1 << 20]u8 = undefined;
    var input = channelEnd(3).readerStreaming(init.io, &input_buffer);
    var output_buffer: [4096]u8 = undefined;
    var output = channelEnd(4).writerStreaming(init.io, &output_buffer);
    while (try input.interface.takeDelimiter('\n')) |line| {
        var scratch_arena: std.heap.ArenaAllocator = .init(init.gpa);
        defer scratch_arena.deinit();
        try answer(init.io, scratch_arena.allocator(), state, &output.interface, line);
    }
}

/// One end of the channel, as the node gives it.
fn channelEnd(descriptor: std.posix.fd_t) Io.File {
    return .{ .handle = descriptor, .flags = .{ .nonblocking = false } };
}

/// Answers the message `line` holds, as the module tells; a line that holds none passed over.
fn answer(io: Io, arena: Allocator, state: []const u8, out: *Io.Writer, line: []const u8) !void {
    const message = std.json.parseFromSliceLeaky(Value, arena, line, .{}) catch return;
    if (message != .object) return;
    const method = message.object.get("method") orelse return;
    const params = message.object.get("params") orelse return;
    if (method != .string or params != .object) return;
    if (std.mem.eql(u8, method.string, "notifications/cancelled")) {
        const id = try std.json.Stringify.valueAlloc(arena, params.object.get("requestId") orelse Value.null, .{});
        return writeDown(io, arena, state, "cancelled", try std.mem.concat(arena, u8, &.{ id, "\n" }));
    }
    if (!std.mem.eql(u8, method.string, "http")) return;
    const id = message.object.get("id") orelse return;
    const path = params.object.get("path").?.string;
    const event_stream = [_][2][]const u8{.{ "content-type", "text/event-stream" }};
    try say(out, .{ .jsonrpc = "2.0", .method = "http/head", .params = .{ .id = id, .status = 200, .headers = &event_stream } });
    if (std.mem.eql(u8, path, "/exit")) std.process.exit(3);
    if (std.mem.eql(u8, path, "/hang")) return say(out, .{ .jsonrpc = "2.0", .method = "http/body", .params = .{ .id = id, .data = "waiting" } });
    const first = try std.fmt.allocPrint(arena, "{s} {s}\n", .{ params.object.get("method").?.string, path });
    try say(out, .{ .jsonrpc = "2.0", .method = "http/body", .params = .{ .id = id, .data = first } });
    var second: std.ArrayList(u8) = .empty;
    for (params.object.get("headers").?.array.items) |pair| try second.print(arena, "{s}: {s}\n", .{ pair.array.items[0].string, pair.array.items[1].string });
    try second.print(arena, "\n{s}", .{if (params.object.get("body")) |body| body.string else ""});
    try say(out, .{ .jsonrpc = "2.0", .method = "http/body", .params = .{ .id = id, .data = second.items } });
    try say(out, .{ .jsonrpc = "2.0", .id = id, .result = .{} });
}

/// Writes `message` as a line on the channel.
fn say(out: *Io.Writer, message: anytype) !void {
    try std.json.Stringify.value(message, .{}, out);
    try out.writeByte('\n');
    try out.flush();
}

/// Adds `text` to the file `name` in the state folder.
fn writeDown(io: Io, arena: Allocator, state: []const u8, name: []const u8, text: []const u8) !void {
    const path = try std.fs.path.join(arena, &.{ state, name });
    const kept = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = try std.mem.concat(arena, u8, &.{ kept, text }) });
}
