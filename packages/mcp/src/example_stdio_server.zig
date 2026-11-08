//! A small MCP server over stdio, built on the server and its stdio runner, for the stdio transport's tests and as an
//! example of serving: three tools, `env` listing its environment's names, `wait` waiting until cancelled and `exit`
//! exiting. Its first argument is the eras it speaks, `modern`, `legacy` or `both`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const protocol = @import("protocol.zig");
const types = @import("types.zig");
const jsonrpc = @import("jsonrpc.zig");
const Server = @import("Server.zig");
const stdio_server = @import("stdio_server.zig");

/// What the tools reach: the io, and the names of the process's environment.
const Context = struct { io: std.Io, environ_names: []const u8 };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const named = if (args.len > 1) args[1] else "both";
    const eras: []const protocol.Era = if (std.mem.eql(u8, named, "legacy")) &.{.legacy} else if (std.mem.eql(u8, named, "modern")) &.{.modern} else &.{ .modern, .legacy };
    var names: std.ArrayList([]const u8) = .empty;
    var it = init.environ_map.iterator();
    while (it.next()) |entry| try names.append(arena, entry.key_ptr.*);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    var context: Context = .{ .io = init.io, .environ_names = try std.mem.join(arena, ",", names.items) };
    var err_buffer: [256]u8 = undefined;
    var err = std.Io.File.stderr().writerStreaming(init.io, &err_buffer);
    try err.interface.writeAll("stdio server ready\n");
    try err.interface.flush();
    const server = try Server.init(init.gpa, init.io, .{
        .info = .{ .name = "example", .version = "1.0.0" },
        .instructions = "Runs in a child process.",
        .tools = .{ .context = &context, .vtable = &.{ .list = list, .call = call } },
        .eras = eras,
    });
    defer server.deinit();
    stdio_server.serve(init.gpa, init.io, server, .{});
}

fn list(_: *anyopaque, arena: Allocator) Allocator.Error![]const types.Tool {
    var schema: std.json.ObjectMap = .empty;
    try schema.put(arena, "type", .{ .string = "object" });
    const object: Value = .{ .object = schema };
    const made = try arena.alloc(types.Tool, 3);
    made[0] = .{ .name = "env", .description = "Lists the names of the process's environment variables.", .inputSchema = object };
    made[1] = .{ .name = "wait", .description = "Waits until cancelled.", .inputSchema = object };
    made[2] = .{ .name = "exit", .description = "Exits the process.", .inputSchema = object };
    return made;
}

fn call(context: *anyopaque, given: *Server.Call, name: []const u8, _: Value) Server.Error!types.CallToolResult {
    const tools: *Context = @ptrCast(@alignCast(context));
    if (std.mem.eql(u8, name, "env")) {
        const content = try given.arena.alloc(types.ContentBlock, 1);
        content[0] = .{ .text = .{ .text = tools.environ_names } };
        return .{ .content = content };
    }
    if (std.mem.eql(u8, name, "wait")) {
        try tools.io.sleep(.fromSeconds(3600), .awake);
        return .{ .content = &.{} };
    }
    if (std.mem.eql(u8, name, "exit")) std.process.exit(3);
    return given.refuse(jsonrpc.codes.invalid_params, "Unknown tool: {s}", .{name});
}
