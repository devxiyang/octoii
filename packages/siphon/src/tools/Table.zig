//! The tools a thread's model may call, as a mount table holds what a namespace reaches: Siphon's own, built in, by
//! their names, and each MCP server's, under the server's name — `<server>.<tool>`; and what a call of any of them does
//! to the machine, which its weighing reads. Each runs by a `tool` request, in a task of its own, once the commit that
//! made the request returned, as everything that acts is asked first: a tool that acts on nothing, cut off, is asked
//! again; one that may act is settled interrupted and never runs twice.
const Table = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const runtime_ = @import("../runtime.zig");
const Runtime = runtime_.Runtime;
const Request = runtime_.Request;
const Tool = @import("Tool.zig");
const threads = @import("../threads.zig");
const Servers = @import("Servers.zig");
const paths = @import("../machine.zig").paths;

allocator: Allocator,
runtime: *Runtime,
/// What the tools are given by the host, each run given it too.
host: Tool.Host,
/// Siphon's own, as they were added; each lives as long as Siphon.
own: std.ArrayList(Tool) = .empty,
/// The person's and the projects' MCP servers, each mounted under its name.
servers: Servers,

pub fn init(runtime: *Runtime, host: Tool.Host) Table {
    return .{ .allocator = runtime.allocator, .runtime = runtime, .host = host, .servers = .init(runtime, host) };
}

pub fn deinit(table: *Table) void {
    table.servers.deinit();
    table.own.deinit(table.allocator);
}

/// Acts on every tool request by running its tool: Siphon's own of its name, else a server's.
pub fn register(table: *Table) !void {
    try table.runtime.handle(Tool.request_name, .{ .context = table, .act = act });
}

/// Adds `tool` to Siphon's own, by its name, which no other tool has.
pub fn add(table: *Table, tool: Tool) !void {
    if (table.named(tool.name) != null) return error.DuplicateTool;
    try table.own.append(table.allocator, tool);
}

/// Siphon's own tool of `name`; null where there is none — a server's may have it.
pub fn named(table: *const Table, name: []const u8) ?Tool {
    for (table.own.items) |tool| if (std.mem.eql(u8, tool.name, name)) return tool;
    return null;
}

/// What a call of `name` with `arguments` does to the machine of a thread working in `workspace`: an own tool's, as it
/// reads its arguments — none where it acts on nothing — and a server's, its tool by name, as one may act on anything;
/// none of a name no tool has, which acts on nothing.
pub fn accessOf(table: *const Table, arena: Allocator, name: []const u8, workspace: ?[]const u8, arguments: []const u8) !?Tool.Access {
    if (table.named(name)) |tool| {
        const read = tool.access orelse return null;
        const base: ?paths.Base = if (workspace) |folder| .{ .workspace = folder, .home = table.host.machine.home } else null;
        return try read(arena, base, arguments);
    }
    if (!namesServerTool(name)) return null;
    const resources = try arena.dupe([]const u8, &.{name});
    return .{ .action = .tool, .resources = resources, .save = resources };
}

/// Whether a call of `name` may act on the machine: an own tool that says what its call does, or any server's.
pub fn mayAct(table: *const Table, name: []const u8) bool {
    const tool = table.named(name) orelse return namesServerTool(name);
    return tool.access != null;
}

/// Whether `name` could name a server's tool, as each is named after its server: `<server>.<tool>`.
fn namesServerTool(name: []const u8) bool {
    return std.mem.indexOfScalar(u8, name, '.') != null;
}

/// Siphon's own tools a thread of `manifest` is offered, as its model is told of them.
pub fn definitions(table: *const Table, arena: Allocator, manifest: *const threads.Manifest) ![]const vocabulary.Tool {
    var out: std.ArrayList(vocabulary.Tool) = .empty;
    for (table.own.items) |tool| {
        if (tool.offered) |offered| if (!offered(manifest)) continue;
        try out.append(arena, .{ .function = .{
            .name = tool.name,
            .description = tool.description,
            .parameters = try foundation.json.Raw.of(arena, tool.parameters),
        } });
    }
    return out.items;
}

fn act(context: ?*anyopaque, request: *Request) anyerror!void {
    const table: *Table = @ptrCast(@alignCast(context.?));
    const arena = request.arena();
    const asked = try foundation.json.decode(Tool.Call, arena, request.payload);
    const tool = table.named(asked.name) orelse return request.answer(try table.servers.call(arena, request.key, asked));
    // A program's call starts its fiber, and asks no request.
    const task = switch (tool.work) {
        .task => |each| each,
        .program => return error.NoSuchTool,
    };
    const run: Tool.Run = .{ .arena = arena, .runtime = table.runtime, .host = &table.host, .thread = asked.thread, .arguments = asked.arguments, .key = request.key, .writes = asked.writes, .waits = &request.task.waits, .request = request };
    try request.answer(try Tool.outcomeOf(&table.host, arena, request.key, try task(tool.context, &run)));
}
