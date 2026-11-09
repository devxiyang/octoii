//! A server run as a child of this process, for the tests of the stdio transport: with exactly the environment it is
//! given, its stderr given line by line to the caller or dropped. This process is its host, and ends it at once as it
//! is stopped: a test's server has nothing to finish.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Process = @import("foundation").jsonrpc.Lines.Process;
const failure_ = @import("../failure.zig");
const Slot = failure_.Slot;
const Error = failure_.Error;

/// Takes each line a server writes to its stderr: its logs.
pub const Lines = struct {
    context: *anyopaque,
    line: *const fn (context: *anyopaque, text: []const u8) void,
};

pub const Child = struct {
    gpa: Allocator,
    io: Io,
    child: std.process.Child,
    command: []u8,
    stderr: ?Lines,
    /// Guards the child's input, which a write, a close of it and the child's end each reach.
    input: Io.Mutex = .init,
    buffer: [16 * 1024]u8 = undefined,
    output: Io.File.Reader = undefined,
    logging: ?Io.Future(void) = null,

    pub const Options = struct {
        command: []const u8,
        args: []const []const u8 = &.{},
        /// The whole environment of the server's process: nothing of this process's goes to it that is not here.
        env: []const [2][]const u8 = &.{},
        cwd: ?[]const u8 = null,
        /// Takes the server's stderr; none, it is dropped.
        stderr: ?Lines = null,
    };

    /// Starts the server's process; `connection_lost` where it cannot start.
    pub fn start(gpa: Allocator, io: Io, slot: *Slot, options: Options) Error!*Child {
        var environ: std.process.Environ.Map = .init(gpa);
        defer environ.deinit();
        for (options.env) |pair| try environ.put(pair[0], pair[1]);
        const argv = try slot.arena.alloc([]const u8, options.args.len + 1);
        argv[0] = options.command;
        @memcpy(argv[1..], options.args);
        const command = try gpa.dupe(u8, options.command);
        errdefer gpa.free(command);
        const made = try gpa.create(Child);
        errdefer gpa.destroy(made);
        const child = std.process.spawn(io, .{
            .argv = argv,
            .environ_map = &environ,
            .cwd = if (options.cwd) |path| .{ .path = path } else .inherit,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = if (options.stderr == null) .ignore else .pipe,
        }) catch return slot.fail(.{ .connection_lost = try slot.arena.print("Could not start the MCP server {s}", .{options.command}) });
        made.* = .{ .gpa = gpa, .io = io, .child = child, .command = command, .stderr = options.stderr };
        made.output = made.child.stdout.?.readerStreaming(io, &made.buffer);
        if (options.stderr != null) made.logging = io.concurrent(readStderr, .{made}) catch null;
        return made;
    }

    pub fn process(child: *Child) Process {
        return .{ .context = child, .vtable = &.{ .write = write, .read = read, .stop = stop, .release = release } };
    }

    fn of(context: *anyopaque) *Child {
        return @ptrCast(@alignCast(context));
    }

    fn write(context: *anyopaque, _: Allocator, line: []const u8) Allocator.Error!?[]const u8 {
        const child = of(context);
        child.input.lockUncancelable(child.io);
        defer child.input.unlock(child.io);
        const stdin = child.child.stdin orelse return "The MCP server's process is not running";
        var buffer: [4096]u8 = undefined;
        var writer = stdin.writerStreaming(child.io, &buffer);
        writer.interface.writeAll(line) catch return "The MCP server's process is not running";
        writer.interface.flush() catch return "The MCP server's process is not running";
        return null;
    }

    /// Reads a line the server wrote, waiting for it; at the end of its output, waits for its exit.
    fn read(context: *anyopaque, arena: Allocator) Allocator.Error!Process.Read {
        const child = of(context);
        var line: Io.Writer.Allocating = .init(arena);
        while (true) {
            line.clearRetainingCapacity();
            const ended = if (child.output.interface.streamDelimiter(&line.writer, '\n')) |_| false else |_| true;
            if (!ended) child.output.interface.toss(1);
            if (line.written().len > 0) return .{ .lines = try arena.dupe([]const u8, &.{line.written()}) };
            if (ended) return .{ .ended = try child.endOf(arena) };
        }
    }

    /// How the server ended, once its output did: its stderr read to its end, and its exit waited for.
    fn endOf(child: *Child, arena: Allocator) Allocator.Error![]const u8 {
        if (child.logging) |*logging| logging.await(child.io);
        child.logging = null;
        closeInput(child);
        const term = child.child.wait(child.io) catch return arena.print("the MCP server {s} ended", .{child.command});
        return switch (term) {
            .exited => |code| arena.print("the MCP server {s} exited with {d}", .{ child.command, code }),
            else => arena.print("the MCP server {s} ended", .{child.command}),
        };
    }

    fn readStderr(child: *Child) void {
        var buffer: [4096]u8 = undefined;
        var reader = child.child.stderr.?.readerStreaming(child.io, &buffer);
        var line: Io.Writer.Allocating = .init(child.gpa);
        defer line.deinit();
        while (true) {
            line.clearRetainingCapacity();
            const ended = if (reader.interface.streamDelimiter(&line.writer, '\n')) |_| false else |_| true;
            if (!ended) reader.interface.toss(1);
            const text = std.mem.trim(u8, line.written(), " \t\r");
            if (text.len > 0) child.stderr.?.line(child.stderr.?.context, text);
            if (ended) return;
        }
    }

    fn closeInput(child: *Child) void {
        child.input.lockUncancelable(child.io);
        defer child.input.unlock(child.io);
        if (child.child.stdin) |stdin| stdin.close(child.io);
        child.child.stdin = null;
    }

    /// Stops the child: its input closed, as a server is asked to end, and killed, as this host ends a server at once,
    /// so its output ends and `read` comes to its end — never waiting, its end the reader's to wait for.
    fn stop(context: *anyopaque) void {
        const child = of(context);
        closeInput(child);
        const id = child.child.id orelse return;
        if (builtin.target.os.tag == .windows) {
            _ = std.os.windows.ntdll.NtTerminateProcess(id, @fromBackingInt(1));
        } else std.posix.kill(id, .KILL) catch {};
    }

    /// Lets the child go, its end waited for where its reader did not come to it.
    fn release(context: *anyopaque) void {
        const child = of(context);
        if (child.logging) |*logging| logging.await(child.io);
        child.child.kill(child.io);
        child.gpa.free(child.command);
        child.gpa.destroy(child);
    }
};
