//! A process on the machine, as Beak runs a command one talks to — a coprocess — for foundation's line peer of JSON-RPC,
//! talked to both ways at once, as events come: what is written is taken at once and reaches its input whole and in
//! order — given to Beak as far as it has room, the rest by the reader as Beak tells of room made, a piece at a time, so
//! a line longer than Beak keeps for a command goes as the process reads it; the whole lines of its output come as
//! Beak tells of them, on a set of the process's own that its reader alone waits on, never polled for — or those of the
//! channel it talks on, as a browser's DevTools do on descriptors of their own, its standard output then kept with its
//! errors; its standard error kept by Beak, the tail of it told as it ends. It runs on the machine it is given, so the
//! host starts no process itself. Stopped, its input is closed, what waits to be written let go, and its reader woken;
//! let go, the machine ends what still runs of it as a server is ended — past a grace terminated, then killed — nobody
//! waiting.
const Coprocess = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Lines = @import("foundation").jsonrpc.Lines;
const beak = @import("../beak.zig");
const h = beak.h;

gpa: Allocator,
io: std.Io,
command: h.beak_handle,
/// The command's own set, which the peer's reader alone waits on.
set: h.beak_handle,
/// The process, as what is told of it names it.
name: []u8,
/// How it ended, once Beak told of it, where lines it wrote came with it: told at the read after theirs.
exit: ?Exit = null,
/// Set as the peer stops it, before its set is woken: its reader tells of its end from then.
stopping: std.atomic.Value(bool) = .init(false),
/// Guards what waits to be written.
lock: std.Io.Mutex = .init,
/// What was written and Beak has not yet taken, in order, from `handed` on.
outgoing: std.ArrayList(u8) = .empty,
handed: usize = 0,
/// Why the process takes nothing more written to it, once Beak refused what waited.
refused: ?[]u8 = null,

const Exit = struct { code: ?i64, signal: ?i64 };

pub const Options = struct {
    io: std.Io,
    machine: h.beak_handle,
    /// The program first, then its arguments.
    argv: []const []const u8,
    cwd: []const u8,
    /// Each set over the machine's own, as env(1) sets them.
    variables: []const [2][]const u8 = &.{},
    /// Whether it starts with the machine's own variables under those it is given; else those alone, as `env -i`.
    inherit: bool = true,
    /// The descriptors it talks on, as a browser's DevTools talk on 3 and 4 — its standard output then kept with its
    /// errors, apart from what it says; none, its standard input and output.
    channel: ?h.beak_channel = null,
    /// What it is called in what is told of it, as "the MCP server docs".
    name: []const u8,
};

/// What starting it came to: the process, or why it could not be started, in the arena given.
pub const Started = union(enum) { coprocess: *Coprocess, failed: []const u8 };

/// Starts the process on the machine; or says why it could not be, in `arena`.
pub fn start(gpa: Allocator, arena: Allocator, options: Options) Allocator.Error!Started {
    const argv = try beak.bytesAll(arena, options.argv);
    const variables = try arena.alloc(h.beak_label, options.variables.len);
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
    const channel = options.channel;
    if (channel) |*descriptors| spawn.channel = descriptors;
    var command: h.beak_handle = 0;
    if (try beak.failed(arena, h.beak_command_spawn(&spawn, &command))) |why| return .{ .failed = try arena.print("{s} could not be started: {s}", .{ options.name, why }) };
    errdefer _ = h.beak_close(command);
    var set: h.beak_handle = 0;
    if (try beak.failed(arena, h.beak_events_open(&set))) |why| return .{ .failed = try arena.print("{s} could not be waited on: {s}", .{ options.name, why }) };
    errdefer _ = h.beak_close(set);
    if (try beak.failed(arena, h.beak_events_add(set, command))) |why| return .{ .failed = try arena.print("{s} could not be waited on: {s}", .{ options.name, why }) };
    const coprocess = try gpa.create(Coprocess);
    errdefer gpa.destroy(coprocess);
    coprocess.* = .{ .gpa = gpa, .io = options.io, .command = command, .set = set, .name = try gpa.dupe(u8, options.name) };
    return .{ .coprocess = coprocess };
}

pub fn process(coprocess: *Coprocess) Lines.Process {
    return .{ .context = coprocess, .vtable = &.{ .write = write, .read = read, .stop = stop, .release = release } };
}

fn of(context: *anyopaque) *Coprocess {
    return @ptrCast(@alignCast(context));
}

/// Takes `line` to be written, never waiting: given to Beak as far as it has room now, the rest as the reader finds room
/// made.
fn write(context: *anyopaque, arena: Allocator, line: []const u8) Allocator.Error!?[]const u8 {
    const coprocess = of(context);
    coprocess.lock.lockUncancelable(coprocess.io);
    defer coprocess.lock.unlock(coprocess.io);
    if (coprocess.refused == null) {
        try coprocess.outgoing.appendSlice(coprocess.gpa, line);
        try coprocess.handOn(arena);
    }
    const why = coprocess.refused orelse return null;
    return try arena.print("{s} takes nothing written to it: {s}", .{ coprocess.name, why });
}

/// How much of what waits is given to Beak at once: a pipe's buffer, so a piece goes once the process read as much.
const piece_bytes_max = 64 * 1024;

/// Gives Beak what waits, a piece at a time, as far as it has room; what waits let go where it takes no more. The lock
/// is held.
fn handOn(coprocess: *Coprocess, arena: Allocator) Allocator.Error!void {
    while (coprocess.handed < coprocess.outgoing.items.len) {
        const rest = coprocess.outgoing.items[coprocess.handed..];
        const piece = rest[0..@min(rest.len, piece_bytes_max)];
        const status = h.beak_command_write(coprocess.command, beak.bytes(piece));
        // Beak keeps no more till the process reads; its set tells the reader of the room made.
        if (status == h.BEAK_BUSY) return;
        if (try beak.failed(arena, status)) |why| {
            coprocess.refused = try coprocess.gpa.dupe(u8, why);
            break;
        }
        coprocess.handed += piece.len;
    }
    coprocess.outgoing.clearAndFree(coprocess.gpa);
    coprocess.handed = 0;
}

/// The whole lines the process wrote since the last read, waiting on its set till there are some — what waits to be
/// written given to Beak as each poll makes room; or how it ended — at once where it is stopped, as each poll looks: a
/// poll takes back the wakes given, so a stop before one is seen after it, and a stop after one wakes the wait.
fn read(context: *anyopaque, arena: Allocator) Allocator.Error!Lines.Process.Read {
    const coprocess = of(context);
    while (true) {
        if (coprocess.exit) |exit| return .{ .ended = try coprocess.endOf(arena, exit) };
        const allocator = beak.outputs(&arena);
        var events: [*c]h.beak_event = null;
        var count: usize = 0;
        var next: h.beak_optional = undefined;
        if (h.beak_events_poll(coprocess.set, 0, &allocator, &events, &count, &next) != h.BEAK_OK) return .{ .ended = try arena.print("{s} could not be read", .{coprocess.name}) };
        var lines: std.ArrayList([]const u8) = .empty;
        for (beak.items(h.beak_event, events, count)) |event| switch (event.type) {
            h.BEAK_EVENT_LINES => for (beak.items(h.beak_bytes, event.items, event.item_count)) |line| try lines.append(arena, beak.slice(line)),
            h.BEAK_EVENT_EXIT => coprocess.exit = .{ .code = beak.get(event.code), .signal = beak.get(event.signal) },
            else => {},
        };
        {
            coprocess.lock.lockUncancelable(coprocess.io);
            defer coprocess.lock.unlock(coprocess.io);
            try coprocess.handOn(arena);
        }
        if (coprocess.stopping.load(.seq_cst)) return .{ .ended = try arena.print("{s} was stopped", .{coprocess.name}) };
        if (lines.items.len > 0) return .{ .lines = lines.items };
        if (coprocess.exit == null) {
            var ready = false;
            _ = h.beak_events_wait(coprocess.set, std.math.maxInt(u32), &ready);
        }
    }
}

/// How the process ended, as what waits on it is told: its exit or signal, then the tail of its standard error.
fn endOf(coprocess: *Coprocess, arena: Allocator, exit: Exit) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    writer.print("{s} ", .{coprocess.name}) catch return error.OutOfMemory;
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

/// How much of the tail of a process's standard error is told as it ends.
const errors_told_max = 2000;

/// Asks the process to end, as a server is asked — its input closed once what was written reaches it — and wakes its
/// reader to tell of its end.
fn stop(context: *anyopaque) void {
    const coprocess = of(context);
    _ = h.beak_command_close_input(coprocess.command);
    coprocess.stopping.store(true, .seq_cst);
    _ = h.beak_events_wake(coprocess.set);
}

/// Lets the process go, nothing reading it: its set closed, then its command, which the machine ends as a server is
/// ended where it still runs.
fn release(context: *anyopaque) void {
    const coprocess = of(context);
    _ = h.beak_close(coprocess.set);
    _ = h.beak_close(coprocess.command);
    coprocess.outgoing.deinit(coprocess.gpa);
    if (coprocess.refused) |why| coprocess.gpa.free(why);
    coprocess.gpa.free(coprocess.name);
    coprocess.gpa.destroy(coprocess);
}
