//! A server's process on the machine, as Beak runs a command one talks to — a coprocess — for mcp's stdio transport:
//! what is written reaches its input whole and in order; the whole lines of its output come as Beak tells of them, on a
//! set of the process's own that its reader alone waits on, never polled for; its standard error kept by Beak, the tail
//! of it told as it ends. It runs where the thread's files are, so the host never starts a server itself. Stopped, its
//! input is closed and its reader woken; let go, the machine ends what still runs of it as a server is ended — past a
//! grace terminated, then killed — nobody waiting.
const Coprocess = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const mcp = @import("mcp");
const Slot = mcp.failure.Slot;
const Error = mcp.failure.Error;
const beak = @import("../beak.zig");
const h = beak.h;

gpa: Allocator,
command: h.beak_handle,
/// The command's own set, which the transport's reader alone waits on.
set: h.beak_handle,
/// The server, as what is told of it names it.
name: []u8,
/// How it ended, once Beak told of it, where lines it wrote came with it: told at the read after theirs.
exit: ?Exit = null,
/// Set as the transport stops it, before its set is woken: its reader tells of its end from then.
stopping: std.atomic.Value(bool) = .init(false),

const Exit = struct { code: ?i64, signal: ?i64 };

pub const Options = struct {
    machine: h.beak_handle,
    /// The program first, then its arguments.
    argv: []const []const u8,
    cwd: []const u8,
    /// Each set over the machine's own, as env(1) sets them.
    variables: []const [2][]const u8 = &.{},
    /// Whether it starts with the machine's own variables under those it is given; else those alone, as `env -i`.
    inherit: bool = true,
    name: []const u8,
};

/// Starts the server on the machine; `connection_lost`, saying why, where it cannot be started.
pub fn start(gpa: Allocator, slot: *Slot, options: Options) Error!*Coprocess {
    const argv = try beak.bytesAll(slot.arena, options.argv);
    const variables = try slot.arena.alloc(h.beak_label, options.variables.len);
    for (options.variables, variables) |pair, *each| each.* = .{ .name = beak.bytes(pair[0]), .value = beak.bytes(pair[1]) };
    var spawn = std.mem.zeroes(h.beak_spawn);
    spawn.machine = options.machine;
    spawn.argv = argv.ptr;
    spawn.argv_count = argv.len;
    spawn.cwd = beak.bytes(options.cwd);
    spawn.variables = variables.ptr;
    spawn.variable_count = variables.len;
    spawn.clear_variables = !options.inherit;
    spawn.mode = h.BEAK_SPAWN_COPROCESS;
    spawn.lines = true;
    var command: h.beak_handle = 0;
    if (try beak.failed(slot.arena, h.beak_command_spawn(&spawn, &command))) |why| return slot.fail(.{ .connection_lost = try std.fmt.allocPrint(slot.arena, "the MCP server {s} could not be started: {s}", .{ options.name, why }) });
    errdefer _ = h.beak_close(command);
    var set: h.beak_handle = 0;
    if (try beak.failed(slot.arena, h.beak_events_open(&set))) |why| return slot.fail(.{ .connection_lost = try std.fmt.allocPrint(slot.arena, "the MCP server {s} could not be waited on: {s}", .{ options.name, why }) });
    errdefer _ = h.beak_close(set);
    if (try beak.failed(slot.arena, h.beak_events_add(set, command))) |why| return slot.fail(.{ .connection_lost = try std.fmt.allocPrint(slot.arena, "the MCP server {s} could not be waited on: {s}", .{ options.name, why }) });
    const coprocess = try gpa.create(Coprocess);
    errdefer gpa.destroy(coprocess);
    coprocess.* = .{ .gpa = gpa, .command = command, .set = set, .name = try gpa.dupe(u8, options.name) };
    return coprocess;
}

pub fn process(coprocess: *Coprocess) mcp.stdio.Process {
    return .{ .context = coprocess, .vtable = &.{ .write = write, .read = read, .stop = stop, .release = release } };
}

fn of(context: *anyopaque) *Coprocess {
    return @ptrCast(@alignCast(context));
}

fn write(context: *anyopaque, arena: Allocator, line: []const u8) Allocator.Error!?[]const u8 {
    const coprocess = of(context);
    const why = try beak.failed(arena, h.beak_command_write(coprocess.command, beak.bytes(line))) orelse return null;
    return try std.fmt.allocPrint(arena, "the MCP server {s} takes nothing written to it: {s}", .{ coprocess.name, why });
}

/// The whole lines the server wrote since the last read, waiting on its set till there are some; or how it ended — at
/// once where it is stopped, as each poll looks: a poll takes back the wakes given, so a stop before one is seen after
/// it, and a stop after one wakes the wait.
fn read(context: *anyopaque, arena: Allocator) Allocator.Error!mcp.stdio.Process.Read {
    const coprocess = of(context);
    while (true) {
        if (coprocess.exit) |exit| return .{ .ended = try coprocess.endOf(arena, exit) };
        const allocator = beak.outputs(&arena);
        var events: [*c]h.beak_event = null;
        var count: usize = 0;
        var next: h.beak_optional = undefined;
        if (h.beak_events_poll(coprocess.set, 0, &allocator, &events, &count, &next) != h.BEAK_OK) return .{ .ended = try std.fmt.allocPrint(arena, "the MCP server {s} could not be read", .{coprocess.name}) };
        var lines: std.ArrayList([]const u8) = .empty;
        for (beak.items(h.beak_event, events, count)) |event| switch (event.type) {
            h.BEAK_EVENT_LINES => for (beak.items(h.beak_bytes, event.items, event.item_count)) |line| try lines.append(arena, beak.slice(line)),
            h.BEAK_EVENT_EXIT => coprocess.exit = .{ .code = beak.get(event.code), .signal = beak.get(event.signal) },
            else => {},
        };
        if (coprocess.stopping.load(.seq_cst)) return .{ .ended = try std.fmt.allocPrint(arena, "the MCP server {s} was stopped", .{coprocess.name}) };
        if (lines.items.len > 0) return .{ .lines = lines.items };
        if (coprocess.exit == null) {
            var ready = false;
            _ = h.beak_events_wait(coprocess.set, std.math.maxInt(u32), &ready);
        }
    }
}

/// How the server ended, as what waits on it is told: its exit or signal, then the tail of its standard error.
fn endOf(coprocess: *Coprocess, arena: Allocator, exit: Exit) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    writer.print("the MCP server {s} ", .{coprocess.name}) catch return error.OutOfMemory;
    if (exit.signal) |signal| {
        writer.print("ended by signal {d}", .{signal}) catch return error.OutOfMemory;
    } else writer.print("exited with {d}", .{exit.code orelse 0}) catch return error.OutOfMemory;
    const allocator = beak.outputs(&arena);
    var errors: h.beak_bytes = undefined;
    if (h.beak_command_output(coprocess.command, &allocator, &errors) == h.BEAK_OK) {
        const said = std.mem.trim(u8, beak.slice(errors), " \t\r\n");
        if (said.len > 0) writer.print(": {s}", .{said[said.len - @min(said.len, errors_told_max) ..]}) catch return error.OutOfMemory;
    }
    return out.written();
}

/// How much of the tail of a server's standard error is told as it ends.
const errors_told_max = 2000;

/// Asks the server to end, as a server is asked — its input closed once what was written reaches it — and wakes its
/// reader to tell of its end.
fn stop(context: *anyopaque) void {
    const coprocess = of(context);
    _ = h.beak_command_close_input(coprocess.command);
    coprocess.stopping.store(true, .seq_cst);
    _ = h.beak_events_wake(coprocess.set);
}

/// Lets the server go, nothing reading it: its set closed, then its command, which the machine ends as a server is
/// ended where it still runs.
fn release(context: *anyopaque) void {
    const coprocess = of(context);
    _ = h.beak_close(coprocess.set);
    _ = h.beak_close(coprocess.command);
    coprocess.gpa.free(coprocess.name);
    coprocess.gpa.destroy(coprocess);
}
