//! The stdio transport against the example server, running in a child process of its own: the stdio server too.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Client = @import("Client.zig");
const transport_ = @import("transport.zig");
const stdio_ = @import("stdio.zig");
const failure_ = @import("failure.zig");

const server_path = @import("test_options").example_stdio_server;

/// A client of the example server in a child process, and what it wrote to its stderr.
const Connected = struct { client: *Client, stderr: *std.ArrayList([]const u8) };

fn connected(a: Allocator, host: *const transport_.Host, eras: []const u8, env: []const [2][]const u8) !Connected {
    const stderr = try a.create(std.ArrayList([]const u8));
    stderr.* = .empty;
    var slot: failure_.Slot = .{ .arena = a };
    const child = try stdio_.Child.start(a, host.io, &slot, .{
        .command = server_path,
        .args = &.{eras},
        .env = env,
        .stderr = .{ .context = stderr, .line = struct {
            fn line(context: *anyopaque, text: []const u8) void {
                const lines: *std.ArrayList([]const u8) = @ptrCast(@alignCast(context));
                lines.append(std.heap.page_allocator, std.heap.page_allocator.dupe(u8, text) catch return) catch {};
            }
        }.line },
    });
    const stdio = try stdio_.Stdio.start(a, host, &slot, child.process(), 1000);
    const made = try Client.connect(a, a, .{ .host = host.*, .client = .{ .name = "test", .version = "1" }, .timeout_ms = 5000, .probe_timeout_ms = 2000 }, stdio.transport());
    return .{ .client = made.client, .stderr = stderr };
}

fn realHost() transport_.Host {
    return .{ .io = std.testing.io };
}

test "a server in a child process is talked to a message a line, its stderr kept apart" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const host = realHost();
    const given = try connected(a, &host, "both", &.{});
    defer given.client.deinit();
    try std.testing.expectEqual(.modern, given.client.era().?);
    try std.testing.expectEqualStrings("Runs in a child process.", given.client.server().?.instructions.?);
    const tools = (try given.client.allTools(a, .{})).done;
    try std.testing.expectEqual(@as(usize, 3), tools.len);
    try std.testing.expectEqualStrings("env", tools[0].name);
    try std.testing.expectEqualStrings("stdio server ready", given.stderr.items[0]);
}

test "a server that speaks only the session-based protocol is spoken to so over stdio" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const host = realHost();
    const given = try connected(a, &host, "legacy", &.{});
    defer given.client.deinit();
    try std.testing.expectEqual(.legacy, given.client.era().?);
    _ = (try given.client.ping(a, .{})).done;
}

test "a server's process starts with exactly the environment it is given" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const host = realHost();
    const given = try connected(a, &host, "modern", &.{.{ "ONLY_THIS", "1" }});
    defer given.client.deinit();
    const listed = (try given.client.callTool(a, "env", null, .{})).done;
    try std.testing.expectEqualStrings("ONLY_THIS", listed.content[0].text.text);
}

test "a request over stdio is cancelled with notifications/cancelled, and the server serves the next" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const host = realHost();
    const given = try connected(a, &host, "modern", &.{});
    defer given.client.deinit();
    _ = (try given.client.callTool(a, "wait", null, .{ .timeout_ms = 50 })).failed.timeout;
    try std.testing.expectEqual(@as(usize, 3), (try given.client.allTools(a, .{})).done.len);
}

test "the transport closes when the server's process exits, saying so" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const host = realHost();
    const given = try connected(a, &host, "modern", &.{});
    defer given.client.deinit();
    const failed = (try given.client.callTool(a, "exit", null, .{})).failed;
    try std.testing.expect(std.mem.endsWith(u8, failed.connection_lost, "exited with 3"));
    try std.testing.expectEqual(.closed, given.client.currentState());
}
