//! The terminals of the threads, where the person works on the machine beside the model, as tmux's server keeps its
//! panes: each a login shell of the person's in its thread's folder, on a terminal Beak keeps — which answers its
//! program's queries, keeps the title it sets and draws itself again whole. Each is numbered in its thread as tmux
//! numbers windows, the lowest number free; sized as its host sizes it; gone as its program ends, as a pane with no
//! `remain-on-exit`; let go of as it is closed, Beak hanging up on it and reaping it; and closed with its thread. What
//! listens is told as a thread's terminals come, take titles and go, and as each writes. The loop alone touches them,
//! told of their output, titles and ends as it pumps.
const Terminals = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const beak = @import("beak.zig");
const h = beak.h;
const Runtime = @import("runtime.zig").Runtime;
const threads = @import("threads.zig");
const Machine = @import("machine.zig");

allocator: Allocator,
runtime: *Runtime,
/// The machine the terminals run on, and the person's shell and home folder there.
machine: Machine.Host,
/// The terminals, by their ids, in the order they were opened.
terminals: std.StringArrayHashMapUnmanaged(*Terminal) = .empty,
listener: ?Listener = null,

/// What hears of the terminals, on the loop: a thread's came, took titles or went; a terminal wrote.
pub const Listener = struct {
    context: *anyopaque,
    changed: *const fn (context: *anyopaque, thread: []const u8) void,
    wrote: *const fn (context: *anyopaque, id: []const u8) void,
};

/// A terminal's size, in cells.
pub const Size = struct {
    rows: u16,
    cols: u16,

    /// The size of a view `rows` by `cols`: a row and a column at least.
    pub fn of(rows: u16, cols: u16) !Size {
        if (rows == 0 or cols == 0) return error.EmptyView;
        return .{ .rows = rows, .cols = cols };
    }

    /// The size two views both show whole: the smaller of each side.
    pub fn fitting(a: Size, b: Size) Size {
        return .{ .rows = @min(a.rows, b.rows), .cols = @min(a.cols, b.cols) };
    }
};

/// A terminal: its id, its thread and its number there; the command Beak runs it as; its size; the bytes it wrote so
/// far, where the next begins; and the title its program set, empty where none.
pub const Terminal = struct {
    terminals: *Terminals,
    id: []const u8,
    thread: []const u8,
    number: u32,
    command: h.beak_handle,
    size: Size,
    written: u64 = 0,
    title: []const u8 = "",

    /// Hears what the terminal did, as the loop pumps: what it wrote, and its title, told to what listens; its end,
    /// which takes it away.
    fn event(context: *anyopaque, told: *const h.beak_event) void {
        const terminal: *Terminal = @ptrCast(@alignCast(context));
        const terminals = terminal.terminals;
        switch (told.type) {
            h.BEAK_EVENT_OUTPUT => {
                terminal.written += told.skipped + told.bytes.len;
                if (terminals.listener) |listener| listener.wrote(listener.context, terminal.id);
            },
            h.BEAK_EVENT_TITLE => {
                // A title that cannot be kept leaves the one before.
                const before = terminal.title;
                terminal.title = terminals.allocator.dupe(u8, beak.slice(told.bytes)) catch return;
                terminals.allocator.free(before);
                terminals.changed(terminal.thread);
            },
            h.BEAK_EVENT_EXIT => terminals.close(terminal),
            else => {},
        }
    }

    /// Keys the person typed, and what they pasted, to the terminal's program.
    pub fn write(terminal: *const Terminal, bytes: []const u8) !void {
        try beak.check(h.beak_command_write(terminal.command, beak.bytes(bytes)));
    }

    /// Sizes the terminal to `size`: whether it changed, as its screen is then drawn again at the new size.
    pub fn resize(terminal: *Terminal, size: Size) !bool {
        if (std.meta.eql(size, terminal.size)) return false;
        try beak.check(h.beak_command_resize(terminal.command, size.rows, size.cols));
        terminal.size = size;
        return true;
    }

    /// What the terminal wrote past `since` bytes, in `arena`, and how many bytes fell out of what Beak keeps before it.
    pub fn outputSince(terminal: *const Terminal, arena: *const Allocator, since: u64) !struct { bytes: []const u8, skipped: u64 } {
        const allocator = beak.outputs(arena);
        var bytes: h.beak_bytes = undefined;
        var skipped: u64 = 0;
        try beak.check(h.beak_command_output_since(terminal.command, since, &allocator, &bytes, &skipped));
        return .{ .bytes = beak.slice(bytes), .skipped = skipped };
    }

    /// The sequences that draw the terminal's screen again whole, in `arena`.
    pub fn screen(terminal: *const Terminal, arena: *const Allocator) ![]const u8 {
        const allocator = beak.outputs(arena);
        var drawn: h.beak_bytes = undefined;
        try beak.check(h.beak_command_screen(terminal.command, true, &allocator, &drawn));
        return beak.slice(drawn);
    }
};

/// How much of a terminal's output Beak keeps for a reader that fell behind to read on from, past which its screen is
/// drawn again.
const kept_bytes = 1 << 20;
/// How much of what scrolls off a terminal's screen it keeps, drawn again with it: some three thousand lines of a
/// build's output, a millisecond's drawing.
const scrollback_bytes = 4 << 20;

/// Closes every terminal, as the host stops.
pub fn deinit(terminals: *Terminals) void {
    for (terminals.terminals.values()) |terminal| terminals.free(terminal);
    terminals.terminals.deinit(terminals.allocator);
}

/// Lets go of a terminal's command — Beak hangs up on one still running, and reaps it — and of the terminal.
fn free(terminals: *Terminals, terminal: *Terminal) void {
    terminals.runtime.unwatch(terminal.command);
    _ = h.beak_close(terminal.command);
    terminals.allocator.free(terminal.title);
    terminals.allocator.free(terminal.id);
    terminals.allocator.free(terminal.thread);
    terminals.allocator.destroy(terminal);
}

fn changed(terminals: *const Terminals, thread: []const u8) void {
    if (terminals.listener) |listener| listener.changed(listener.context, thread);
}

/// A terminal opened for the thread `thread`, `size` big: the person's login shell in the thread's folder, else in
/// their home folder.
pub fn open(terminals: *Terminals, arena: Allocator, thread: []const u8, size: Size) !*Terminal {
    const machine = terminals.machine.handle orelse return error.NoMachine;
    const shell = terminals.machine.shell orelse return error.NoShell;
    const manifest = threads.manifestOf(terminals.runtime.volume, &arena, try threads.pathOf(arena, thread)) catch |err| switch (err) {
        error.NotFound => return error.NoSuchThread,
        else => return err,
    };
    const argv = [_]h.beak_bytes{ beak.bytes(shell), beak.bytes("-l") };
    const variables = [_]h.beak_label{
        .{ .name = beak.bytes("TERM"), .value = beak.bytes("xterm-256color") },
        .{ .name = beak.bytes("COLORTERM"), .value = beak.bytes("truecolor") },
    };
    var spawn = std.mem.zeroes(h.beak_spawn);
    spawn.machine = machine;
    spawn.argv = &argv;
    spawn.argv_count = argv.len;
    spawn.cwd = beak.bytes(manifest.workspace orelse terminals.machine.home orelse "/");
    spawn.variables = &variables;
    spawn.variable_count = variables.len;
    spawn.mode = h.BEAK_SPAWN_TERMINAL;
    spawn.rows = size.rows;
    spawn.cols = size.cols;
    spawn.scrollback_bytes = scrollback_bytes;
    spawn.tail_bytes = kept_bytes;
    var command: h.beak_handle = 0;
    try beak.check(h.beak_command_spawn(&spawn, &command));
    errdefer _ = h.beak_close(command);
    const terminal = try terminals.allocator.create(Terminal);
    errdefer terminals.allocator.destroy(terminal);
    const id = try terminals.allocator.dupe(u8, &try terminals.runtime.volume.mint(terminals.runtime.now()));
    errdefer terminals.allocator.free(id);
    const owner = try terminals.allocator.dupe(u8, thread);
    errdefer terminals.allocator.free(owner);
    terminal.* = .{ .terminals = terminals, .id = id, .thread = owner, .number = terminals.freeNumber(thread), .command = command, .size = size };
    try terminals.terminals.put(terminals.allocator, id, terminal);
    errdefer _ = terminals.terminals.orderedRemove(id);
    try terminals.runtime.watch(command, .{ .context = terminal, .event = Terminal.event });
    terminals.changed(thread);
    return terminal;
}

/// The lowest number no terminal of `thread` has, from 1.
fn freeNumber(terminals: *const Terminals, thread: []const u8) u32 {
    var number: u32 = 1;
    while (true) : (number += 1) {
        const taken = for (terminals.terminals.values()) |terminal| {
            if (terminal.number == number and std.mem.eql(u8, terminal.thread, thread)) break true;
        } else false;
        if (!taken) return number;
    }
}

/// The terminal `id`; error.NoSuchTerminal where there is none.
pub fn get(terminals: *const Terminals, id: []const u8) !*Terminal {
    return terminals.terminals.get(id) orelse error.NoSuchTerminal;
}

/// Takes a terminal away, its command let go of, and tells what listens of its thread.
pub fn close(terminals: *Terminals, terminal: *Terminal) void {
    const thread = terminal.thread;
    _ = terminals.terminals.orderedRemove(terminal.id);
    terminals.changed(thread);
    terminals.free(terminal);
}

/// Takes away every terminal of the thread `tid`, as the thread goes.
pub fn closeThread(terminals: *Terminals, tid: []const u8) void {
    var index = terminals.terminals.count();
    while (index > 0) {
        index -= 1;
        const terminal = terminals.terminals.values()[index];
        if (std.mem.eql(u8, terminal.thread, tid)) terminals.close(terminal);
    }
}

/// The terminals of the thread `thread`, in the order they were opened.
pub fn ofThread(terminals: *const Terminals, arena: Allocator, thread: []const u8) ![]const *Terminal {
    var found: std.ArrayList(*Terminal) = .empty;
    for (terminals.terminals.values()) |terminal| if (std.mem.eql(u8, terminal.thread, thread)) try found.append(arena, terminal);
    return found.items;
}
