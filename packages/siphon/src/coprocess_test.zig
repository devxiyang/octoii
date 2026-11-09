//! A server's process on the machine, as Coprocess runs one for mcp's stdio transport: mcp's example server, talked to
//! a line at a time with the machine's variables and those it is given, or those alone; and one that exits unasked,
//! its transport closed with how it ended.
const std = @import("std");
const Allocator = std.mem.Allocator;
const mcp = @import("mcp");
const beak = @import("beak.zig");
const h = beak.h;
const Coprocess = @import("tools.zig").Coprocess;
const testing = @import("testing.zig");
const server_path = @import("test_options").example_stdio_server;

/// A client of mcp's example server, run on the local machine with `variables` set over the machine's own.
fn connectedExample(arena: Allocator, host: *const mcp.transport.Host, machine: h.beak_handle, variables: []const [2][]const u8) !*mcp.Client {
    var slot: mcp.failure.Slot = .{ .arena = arena };
    // The build names the server from where it runs, as the machine names nothing.
    const program = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, server_path, arena);
    const coprocess = try Coprocess.start(std.testing.allocator, &slot, .{ .machine = machine, .argv = &.{ program, "both" }, .cwd = "/", .variables = variables, .name = "example" });
    const stdio = try mcp.stdio.Stdio.start(std.testing.allocator, host, &slot, coprocess.process());
    const connected = try mcp.Client.connect(std.testing.allocator, arena, .{ .host = host.*, .client = .{ .name = "test", .version = "1" }, .timeout_ms = 5000, .probe_timeout_ms = 2000 }, stdio.transport());
    return connected.client;
}

test "a server run on the machine is talked to a line at a time, with the machine's variables and those it is given" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const machine = try testing.openLocalMachine();
    defer _ = h.beak_close(machine);
    const host: mcp.transport.Host = .{ .io = std.testing.io };
    const client = try connectedExample(arena, &host, machine, &.{.{ "OCTOII_GIVEN", "1" }});
    defer client.deinit();
    const listed = (try client.allTools(arena, .{})).done;
    try std.testing.expectEqual(@as(usize, 3), listed.len);
    try std.testing.expectEqualStrings("env", listed[0].name);
    const named = (try client.callTool(arena, "env", null, .{})).done.content[0].text.text;
    var names = std.mem.splitScalar(u8, named, ',');
    var found: usize = 0;
    while (names.next()) |name| {
        if (std.mem.eql(u8, name, "PATH") or std.mem.eql(u8, name, "OCTOII_GIVEN")) found += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), found);
}

test "a server that inherits nothing starts with the variables it is given alone" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const machine = try testing.openLocalMachine();
    defer _ = h.beak_close(machine);
    const host: mcp.transport.Host = .{ .io = std.testing.io };
    var slot: mcp.failure.Slot = .{ .arena = arena };
    const program = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, server_path, arena);
    const coprocess = try Coprocess.start(std.testing.allocator, &slot, .{ .machine = machine, .argv = &.{ program, "both" }, .cwd = "/", .variables = &.{.{ "OCTOII_GIVEN", "1" }}, .inherit = false, .name = "example" });
    const stdio = try mcp.stdio.Stdio.start(std.testing.allocator, &host, &slot, coprocess.process());
    const client = (try mcp.Client.connect(std.testing.allocator, arena, .{ .host = host, .client = .{ .name = "test", .version = "1" }, .timeout_ms = 5000, .probe_timeout_ms = 2000 }, stdio.transport())).client;
    defer client.deinit();
    try std.testing.expectEqualStrings("OCTOII_GIVEN", (try client.callTool(arena, "env", null, .{})).done.content[0].text.text);
}

test "a server that exits unasked closes its transport, saying how it ended and what it wrote to its standard error" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const machine = try testing.openLocalMachine();
    defer _ = h.beak_close(machine);
    const host: mcp.transport.Host = .{ .io = std.testing.io };
    const client = try connectedExample(arena, &host, machine, &.{});
    defer client.deinit();
    const exited = try client.callTool(arena, "exit", null, .{});
    try std.testing.expectStringStartsWith(exited.failed.connection_lost, "The MCP connection closed: the MCP server example exited with 3: stdio server ready");
    try std.testing.expectEqual(mcp.Client.State.closed, client.currentState());
}

test "a server's transport closes without waiting on its end, which the machine brings as a server's: by its input's end, else a terminate" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const folder = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const machine = try testing.openLocalMachine();
    const host: mcp.transport.Host = .{ .io = std.testing.io };
    // Each writes down what asked it to end: the one that reads, its input's end; the one that reads not, the terminate
    // its machine gives it past a grace; neither hung up on.
    const scripts = [_][]const u8{
        "trap 'echo hangup >> \"$1\"' HUP; cat > /dev/null; echo input >> \"$1\"",
        "trap 'echo hangup >> \"$1\"' HUP; trap 'echo terminate >> \"$1\"; exit 0' TERM; while :; do sleep 0.05; done",
    };
    const names = [_][]const u8{ "reads", "reads-not" };
    for (scripts, names) |script, name| {
        var slot: mcp.failure.Slot = .{ .arena = arena };
        const file = try std.fs.path.join(arena, &.{ folder, name });
        const coprocess = try Coprocess.start(std.testing.allocator, &slot, .{ .machine = machine, .argv = &.{ "/bin/sh", "-c", script, "sh", file }, .cwd = "/", .name = name });
        const stdio = try mcp.stdio.Stdio.start(std.testing.allocator, &host, &slot, coprocess.process());
        const began = std.Io.Clock.awake.now(std.testing.io).toMilliseconds();
        stdio.transport().close();
        try std.testing.expect(std.Io.Clock.awake.now(std.testing.io).toMilliseconds() - began < 500);
    }
    // Closing the machine waits for what it ends, its graces at most.
    _ = h.beak_close(machine);
    for (names, [_][]const u8{ "input\n", "terminate\n" }) |name, asked| {
        const written = try tmp.dir.readFileAlloc(std.testing.io, name, arena, .unlimited);
        try std.testing.expectEqualStrings(asked, written);
    }
}
