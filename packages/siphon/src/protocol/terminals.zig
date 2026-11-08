//! The threads' terminals as clients see them, as tmux's clients attach to its panes: a terminal opened for a thread,
//! typed into and closed; followed in a view of its own size, the terminal sized to the smallest of its views, as
//! tmux's `window-size smallest`, each drawn again as the size changes; each follower fed from where it stands — its
//! screen drawn again where it stands nowhere or fell behind past what Beak keeps. The clients following a thread are
//! told of its terminals as they come, take titles and go.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const Terminals = @import("../terminals.zig");
const Size = Terminals.Size;
const Connection = @import("Connection.zig");
const Clients = @import("Clients.zig");

/// A terminal opened for a thread at the size of the view that opens it: the person's login shell in the thread's
/// folder, else in their home folder; its id.
pub fn open(connection: *Connection, arena: Allocator, id: []const u8, given: struct { thread: []const u8, rows: u16, cols: u16 }) !void {
    const terminal = try connection.clients.terminals.open(arena, given.thread, try .of(given.rows, given.cols));
    return connection.answer(arena, id, .{ .terminal = terminal.id });
}

/// Keys the person typed, and what they pasted, to a terminal's program.
pub fn write(connection: *Connection, arena: Allocator, id: []const u8, given: struct { terminal: []const u8, data: []const u8 }) !void {
    try (try connection.clients.terminals.get(given.terminal)).write(given.data);
    return connection.answer(arena, id, Connection.nothing);
}

/// A terminal closed: let go of, and gone from its thread.
pub fn close(connection: *Connection, arena: Allocator, id: []const u8, given: struct { terminal: []const u8 }) !void {
    const terminals = connection.clients.terminals;
    terminals.close(try terminals.get(given.terminal));
    return connection.answer(arena, id, Connection.nothing);
}

/// A terminal followed in a view `rows` by `cols`, from `from`, the bytes it had written where the client stood — its
/// screen drawn first where it stands nowhere — fed as the pump ends; the terminal sized to its views again.
pub fn follow(connection: *Connection, arena: Allocator, id: []const u8, given: struct { terminal: []const u8, rows: u16, cols: u16, from: ?u64 = null }) !void {
    const clients = connection.clients;
    _ = try clients.terminals.get(given.terminal);
    try connection.following.followTerminal(given.terminal, given.from, try .of(given.rows, given.cols));
    try fit(clients, given.terminal);
    return connection.answer(arena, id, Connection.nothing);
}

/// A terminal the client follows shown in a view `rows` by `cols` now; the terminal sized to its views again.
pub fn resize(connection: *Connection, arena: Allocator, id: []const u8, given: struct { terminal: []const u8, rows: u16, cols: u16 }) !void {
    try connection.following.resizeTerminal(given.terminal, try .of(given.rows, given.cols));
    try fit(connection.clients, given.terminal);
    return connection.answer(arena, id, Connection.nothing);
}

/// A terminal no longer followed; the terminal sized to the views left.
pub fn unfollow(connection: *Connection, arena: Allocator, id: []const u8, given: struct { terminal: []const u8 }) !void {
    connection.following.unfollowTerminal(given.terminal);
    try fit(connection.clients, given.terminal);
    return connection.answer(arena, id, Connection.nothing);
}

/// Sizes the terminal `id`, where there is one, to the views the clients following it show it in; one no client shows
/// keeps its size. A size that changes draws it again for each client that follows it.
pub fn fit(clients: *Clients, id: []const u8) !void {
    const terminal = clients.terminals.get(id) catch return;
    const size = clients.fitted(Size, "terminals", id) orelse return;
    if (try terminal.resize(size)) clients.terminalRedrawn(id);
}

/// Where a client following a terminal stands: the size of the view it shows it in; the bytes it was sent up to, none
/// where it stands nowhere yet and is to be drawn its screen; and whether the terminal may hold what it was not sent.
pub const Follow = struct { size: Size, sent: ?u64 = null, changed: bool = true };

/// Sends a client following the terminal `id` what it was not sent: what the terminal wrote since it stood — or its
/// screen drawn again, where it stands nowhere, or what it missed fell out of what Beak keeps — marked unchanged where
/// nothing is left. A terminal gone sends nothing.
pub fn send(terminals: *const Terminals, connection: *Connection, arena: Allocator, id: []const u8, follower: *Follow) !void {
    const terminal = terminals.get(id) catch {
        follower.changed = false;
        return;
    };
    if (follower.sent) |sent| if (sent < terminal.written) {
        const output = try terminal.outputSince(&arena, sent);
        if (output.skipped == 0) {
            connection.send(try foundation.json.encode(arena, .{ .event = "terminal-output", .terminal = id, .offset = sent, .data = foundation.json.Base64{ .bytes = output.bytes } }));
            follower.sent = sent + output.bytes.len;
        } else follower.sent = null;
    };
    if (follower.sent == null) {
        const drawn = .{ .event = "terminal-screen", .terminal = id, .offset = terminal.written, .rows = terminal.size.rows, .cols = terminal.size.cols, .screen = foundation.json.Base64{ .bytes = try terminal.screen(&arena) } };
        connection.send(try foundation.json.encode(arena, drawn));
        follower.sent = terminal.written;
    }
    follower.changed = follower.sent.? < terminal.written;
}

/// A terminal as a client following its thread is told of it: its id, its number in the thread, and the title its
/// program set, where it set one.
const Listed = struct { id: []const u8, number: u32, title: ?[]const u8 = null };

/// The message that tells a client following the thread `thread` of its terminals, in the order they were opened.
pub fn listEvent(terminals: *const Terminals, arena: Allocator, thread: []const u8) ![]const u8 {
    var listed: std.ArrayList(Listed) = .empty;
    for (try terminals.ofThread(arena, thread)) |terminal| {
        try listed.append(arena, .{ .id = terminal.id, .number = terminal.number, .title = if (terminal.title.len > 0) terminal.title else null });
    }
    return foundation.json.encode(arena, .{ .event = "terminals", .thread = thread, .terminals = listed.items });
}
