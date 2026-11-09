//! A tool a thread's model may call: its name, what it does, the JSON Schema its arguments fit, what a call of it does
//! to the machine — read from the call's arguments, for its thread's permissions to weigh; none for a tool that acts on
//! nothing — and what does its work: a run in its request's task, or a fiber of a program its call starts. What a run
//! gives is told the model as every tool's is: its text as it is, then its notes, bounded, the whole of it kept where it
//! is cut; and how a call ended is its outcome, as its turn appends it.
const Tool = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const typebox = @import("typebox");
const runtime_ = @import("../runtime.zig");
const Runtime = runtime_.Runtime;
const Request = runtime_.Request;
const Waits = runtime_.Waits;
const threads = @import("../threads.zig");
const log = threads.log;
const Machine = @import("../machine.zig");

name: []const u8,
description: []const u8,
/// The JSON Schema of its arguments, which a call's arguments must fit.
parameters: []const u8,
/// What a call of it does to the machine, read from the call's arguments, which fit its parameters, and from where its
/// thread's paths start, none where the thread has no workspace; none for a tool that acts on nothing — its call goes
/// ahead in every mode, and a run of it cut off runs again.
access: ?*const fn (arena: Allocator, base: ?Machine.paths.Base, arguments: []const u8) anyerror!Access = null,
/// Whether its calls run alone — after the reply's calls before them ended, and before those after begin — though they
/// say nothing of what they do to the machine, as a script's, whose calls may act, and a page's actions do. One that
/// says what its call does runs alone where the call may act; any other runs at once with its neighbours that do.
alone: bool = false,
context: ?*anyopaque = null,
work: Work,
/// Whether a thread of `manifest` is offered it; none, every thread is.
offered: ?*const fn (manifest: *const threads.Manifest) bool = null,

/// The name of a tool's request.
pub const request_name = "tool";

/// What a call does to the machine, as its thread's permissions weigh it: its action; what it acts on, as far as it
/// can be read — the files it edits, by their absolute paths; each simple command it runs; the tool that may act on
/// anything, by its name — none where nothing can be, as of a command line no reading knows whole, which no grant lets
/// go ahead; the patterns an always grants its thread's project; whether it asks to write beyond the sandbox, and why;
/// and whether every command it runs reads alone.
pub const Access = struct {
    action: Action,
    resources: []const []const u8,
    save: []const []const u8,
    escalate: bool = false,
    justification: ?[]const u8 = null,
    reads_alone: bool = false,
};

/// What a call does: edits files; runs commands; or acts through a tool that may do anything, as a server's may.
pub const Action = enum { edit, command, tool };

/// Where a call's commands may write, as its weighing let it go ahead: its thread's workspace and the machine's
/// temporary folders alone, as the system's sandbox keeps them where the machine sandboxes commands; or anywhere.
pub const Writes = enum { workspace, anywhere };

/// What the tools are given by the host: the machine threads work on; the folder a tool keeps what it could not give
/// whole in, a file for each call, for the model to read; and the file of the person's own MCP servers, for every
/// project — none of either where the host keeps none.
pub const Host = struct {
    machine: Machine.Host = .{},
    outputs: ?[]const u8 = null,
    mcp: ?[]const u8 = null,
};

/// What does a tool's work: a run in its request's task, which gives what the model reads; or a fiber of a program its
/// call starts, the call's arguments its input and its result the call's outcome, as a tool that is a program of its own
/// — a script — runs.
pub const Work = union(enum) {
    task: *const fn (context: ?*anyopaque, run: *const Run) anyerror!Output,
    program: []const u8,
};

/// What a tool's run is given: its arguments, which fit its parameters; the thread whose model called it, by its id;
/// memory that lasts the run; the runtime, and what the tools are given by the host; its request's key, which names
/// this run alone, as a file it keeps is named; and where its commands may write, as its call's weighing gave.
pub const Run = struct {
    arena: Allocator,
    runtime: *Runtime,
    host: *const Host,
    thread: []const u8,
    arguments: []const u8,
    key: []const u8,
    writes: Writes,
    /// What the run waits on for news of what it starts, which a stop wakes.
    waits: *Waits,
    /// The request the run answers, on whose stream it tells what it does as it goes; none where nothing follows it.
    request: ?*Request = null,

    /// Tells `text`, what the run's tool does as it goes — a command's output as it comes — on its request's stream,
    /// for those who follow its thread, as `{"text": …}`, in memory `scratch_arena` lends; nothing where nothing follows it.
    pub fn tell(run: *const Run, scratch_arena: Allocator, text: []const u8) !void {
        const request = run.request orelse return;
        if (text.len == 0) return;
        try request.publish(run.thread, try foundation.json.encode(scratch_arena, .{ .text = text }));
    }

    /// The machine as the run reaches it: its paths starting at its thread's workspace, the threads shown.
    pub fn openMachine(run: *const Run) !Machine {
        const manifest = try threads.manifestOf(run.runtime.volume, &run.arena, try threads.pathOf(run.arena, run.thread));
        const base: Machine.paths.Base = .{ .workspace = manifest.workspace orelse return error.NoWorkspace, .home = run.host.machine.home };
        return Machine.open(run.host.machine, .{ .base = base, .threads = run.runtime.volume });
    }
};

/// What a tool's run gave, as every tool gives it: its text, as it is — a file's lines, a command's output, Beak's own
/// words for a failure — and the notes on it, each a fact the model may act on that the text cannot hold: what it
/// leaves out and how to go on, how a command ended, how an edit matched; and whether the tool did what it was asked
/// or refused, as an edit of text not there.
pub const Output = struct {
    outcome: enum { done, refused } = .done,
    text: []const u8,
    notes: []const []const u8 = &.{},
    /// The files it hands the model beside its text — an image read — each kept by its reference.
    files: []const log.OutputFile = &.{},
};

/// The notes of a tool's output, as its run gathers them, in memory that lasts the run.
pub const Notes = struct {
    arena: Allocator,
    list: std.ArrayList([]const u8) = .empty,

    pub fn add(notes: *Notes, comptime format: []const u8, arguments: anytype) Allocator.Error!void {
        try notes.list.append(notes.arena, try notes.arena.print(format, arguments));
    }
};

/// What a tool's request asks: the tool by its name, with the call's arguments, for the thread `thread`, by its id —
/// its commands writing where its weighing let them.
pub const Call = struct { name: []const u8, arguments: []const u8, thread: []const u8, writes: Writes };

/// Why `arguments` do not fit the tool's parameters, for the model to read; null where they fit.
pub fn argumentsProblem(tool: Tool, arena: Allocator, arguments: []const u8) !?[]const u8 {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, arguments, .{}) catch return "The arguments are not JSON.";
    if (value != .object) return "The arguments are not a JSON object.";
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena, tool.parameters, .{});
    const found = try typebox.problems(arena, schema, value);
    if (found.len == 0) return null;
    return try typebox.shown(arena, found);
}

/// How a call ended, as `output` says, under the request `key`: what the tool gave, as the model is told it — bounded,
/// its notes after it — done where it did what it was asked, its error where it refused.
pub fn outcomeOf(host: *const Host, arena: Allocator, key: []const u8, output: Output) !log.CallOutcome {
    const shown = try bounded(host, arena, key, try told(arena, output));
    return .{ .status = if (output.outcome == .done) .ok else .@"tool-error", .output = shown, .files = output.files };
}

/// The outcome `status` with a note of Siphon's own, as the model reads one.
pub fn noted(arena: Allocator, status: log.CallStatus, note: []const u8) Allocator.Error!log.CallOutcome {
    return .{ .status = status, .output = try told(arena, .{ .text = "", .notes = &.{note} }) };
}

/// The outcome of a call a stop came before it ran.
pub fn stoppedBefore(arena: Allocator) Allocator.Error!log.CallOutcome {
    return noted(arena, .stopped, "stopped before it ran");
}

/// The most bytes of a tool's output the model is told; past them it is cut, and the whole of it kept for the model
/// to read.
pub const told_bytes_max = 50 * 1024;

/// `text` as the model is told it: whole within `told_bytes_max`; past it, cut after the last line that fits, with a
/// note of where the whole of it is kept — the host's outputs folder, as the file `<key>.txt`.
pub fn bounded(host: *const Host, arena: Allocator, key: []const u8, text: []const u8) ![]const u8 {
    if (text.len <= told_bytes_max) return text;
    const end = if (std.mem.lastIndexOfScalar(u8, text[0..told_bytes_max], '\n')) |at| at + 1 else told_bytes_max;
    const note = if (try keep(host, arena, try std.mem.concat(arena, u8, &.{ key, ".txt" }), text)) |path|
        try arena.print("cut at {d} of {d} bytes; all of it in {s}", .{ end, text.len, path })
    else
        try arena.print("cut at {d} of {d} bytes", .{ end, text.len });
    return told(arena, .{ .text = text[0..end], .notes = &.{note} });
}

/// Keeps `bytes` as the file `name` of the host's outputs folder, on the machine: its path; none where the host keeps no
/// outputs.
fn keep(host: *const Host, arena: Allocator, name: []const u8, bytes: []const u8) !?[]const u8 {
    const folder = host.outputs orelse return null;
    const machine = Machine.open(host.machine, .{ .base = .{ .workspace = folder } }) catch |err| switch (err) {
        error.NoMachine => return null,
        else => return err,
    };
    defer machine.close();
    const path = try std.fs.path.join(arena, &.{ folder, name });
    try machine.writeAll(arena, path, bytes);
    return path;
}

/// `output` as the model reads it: its text as it is, then each note on a line of its own, in brackets.
pub fn told(arena: Allocator, output: Output) Allocator.Error![]const u8 {
    if (output.notes.len == 0) return output.text;
    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    writer.writeAll(output.text) catch return error.OutOfMemory;
    if (output.text.len > 0 and output.text[output.text.len - 1] != '\n') writer.writeByte('\n') catch return error.OutOfMemory;
    for (output.notes, 0..) |note, i| {
        writer.print("{s}[{s}]", .{ if (i > 0) "\n" else "", note }) catch return error.OutOfMemory;
    }
    return out.written();
}
