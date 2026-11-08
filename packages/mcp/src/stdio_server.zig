//! A server over stdio: a message a line read from its stdin and handed to the server, what it sends written a line to
//! its stdout, one message at a time from whichever task sends it. It serves until its stdin ends, as its client
//! closing it does, then stops the server's tasks. Its stderr is the host's own, for its logs.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Server = @import("Server.zig");

pub const Options = struct {
    input: Io.File = .stdin(),
    output: Io.File = .stdout(),
};

/// Serves `server` until its input ends or the task is cancelled.
pub fn serve(gpa: Allocator, io: Io, server: *Server, options: Options) void {
    var out_buffer: [64 * 1024]u8 = undefined;
    var writer = options.output.writerStreaming(io, &out_buffer);
    var output: Output = .{ .io = io, .writer = &writer.interface };
    const peer: Server.Peer = .{ .context = &output, .send = Output.send };
    defer server.stop();
    var in_buffer: [64 * 1024]u8 = undefined;
    var reader = options.input.readerStreaming(io, &in_buffer);
    var line: Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    while (true) {
        line.clearRetainingCapacity();
        const ended = if (reader.interface.streamDelimiter(&line.writer, '\n')) |_| false else |err| switch (err) {
            error.EndOfStream => true,
            else => return,
        };
        if (!ended) reader.interface.toss(1);
        const text = std.mem.trim(u8, line.written(), " \t\r");
        if (text.len > 0) server.handle(peer, text);
        if (ended) return;
    }
}

/// The server's stdout, written a message at a time.
const Output = struct {
    io: Io,
    lock: Io.Mutex = .init,
    writer: *Io.Writer,

    /// Writes `message` whole, a task's cancellation held off till it is, so that no line is left half written.
    fn send(context: *anyopaque, message: []const u8) void {
        const output: *Output = @ptrCast(@alignCast(context));
        const protection = output.io.swapCancelProtection(.blocked);
        defer _ = output.io.swapCancelProtection(protection);
        output.lock.lockUncancelable(output.io);
        defer output.lock.unlock(output.io);
        output.writer.writeAll(message) catch return;
        output.writer.writeAll("\n") catch return;
        output.writer.flush() catch return;
    }
};
