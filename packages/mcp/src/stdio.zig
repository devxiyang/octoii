//! The stdio transport: the server a process — a child of this one, or one its host runs elsewhere, as a command on a
//! machine — talked to a JSON-RPC message a line: each written to its input whole, each line it writes routed to the
//! request it is for, the rest apart. A task on the host's io reads the process until it ends, and its end closes the
//! transport, saying how where nobody asked it to. Closing the transport ends the server as a session ends: its input
//! closed, a while given it to exit, then killed.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const jsonrpc = @import("jsonrpc.zig");
const protocol = @import("protocol.zig");
const transport_ = @import("transport.zig");
const Host = transport_.Host;
const Incoming = transport_.Incoming;
const router_ = @import("router.zig");
const failure_ = @import("failure.zig");
const Slot = failure_.Slot;
const Error = failure_.Error;

/// A server's process, as the transport talks to it.
pub const Process = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Writes `line`, its newline with it, to the process's input, whole: null, or why it could not, in `arena`.
        write: *const fn (context: *anyopaque, arena: Allocator, line: []const u8) Allocator.Error!?[]const u8,
        /// Waits for what the process writes next: the whole lines it wrote, or how it ended, in `arena`.
        read: *const fn (context: *anyopaque, arena: Allocator) Allocator.Error!Read,
        /// Closes the process's input, so it reads to its end.
        closeInput: *const fn (context: *anyopaque) void,
        /// Ends the process, and all it started; `read` tells of its end as ever.
        kill: *const fn (context: *anyopaque) void,
        /// Lets the process go, once `read` told of its end.
        release: *const fn (context: *anyopaque) void,
    };

    /// What a read came to: the lines the process wrote, each without its newline; or, where it ended, how.
    pub const Read = union(enum) { lines: []const []const u8, ended: []const u8 };
};

pub const Stdio = struct {
    gpa: Allocator,
    host: *const Host,
    router: router_.Router,
    process: Process,
    /// How long the server has to exit once its input is closed, before it is killed.
    shutdown_ms: u64,
    /// Set as the transport closes: the server's end, from then, is asked for.
    closing: std.atomic.Value(bool) = .init(false),
    reading: ?Io.Future(void) = null,

    /// Talks to the server `process` runs, which the transport owns from here; `connection_lost` where the host's io
    /// cannot read it.
    pub fn start(gpa: Allocator, host: *const Host, slot: *Slot, process: Process, shutdown_ms: u64) Error!*Stdio {
        const stdio = gpa.create(Stdio) catch |err| {
            discard(gpa, process);
            return err;
        };
        stdio.* = .{ .gpa = gpa, .host = host, .router = .init(gpa, host), .process = process, .shutdown_ms = shutdown_ms };
        stdio.reading = host.io.concurrent(readAll, .{stdio}) catch {
            discard(gpa, process);
            stdio.router.deinit();
            gpa.destroy(stdio);
            return slot.fail(.{ .connection_lost = "The host's io runs nothing concurrently, which a server over stdio needs" });
        };
        return stdio;
    }

    pub fn transport(stdio: *Stdio) transport_.Transport {
        return .{ .context = stdio, .vtable = &.{ .request = request, .send = send, .receive = receive, .negotiated = negotiated, .isClosed = isClosed, .close = close } };
    }

    fn of(context: *anyopaque) *Stdio {
        return @ptrCast(@alignCast(context));
    }

    /// Routes each line the server writes, until it ends: its end closes the channel, saying how where it was not
    /// asked to end.
    fn readAll(stdio: *Stdio) void {
        var arena_state: std.heap.ArenaAllocator = .init(stdio.gpa);
        defer arena_state.deinit();
        while (true) {
            _ = arena_state.reset(.retain_capacity);
            const read = stdio.process.vtable.read(stdio.process.context, arena_state.allocator()) catch {
                stdio.router.shut("the MCP server's process could not be read");
                return;
            };
            switch (read) {
                .lines => |lines| for (lines) |line| {
                    const text = std.mem.trim(u8, line, " \t\r");
                    if (text.len > 0) stdio.router.arrive(text) catch {};
                },
                .ended => |how| return stdio.router.shut(if (stdio.closing.load(.acquire)) null else how),
            }
        }
    }

    /// Writes `message` as a line to the server's input.
    fn write(stdio: *Stdio, slot: *Slot, message: jsonrpc.Message) Error!void {
        if (stdio.router.isClosed()) return slot.fail(.{ .connection_lost = "The MCP server's process is not running" });
        const line = try std.mem.concat(slot.arena, u8, &.{ try message.encode(slot.arena), "\n" });
        if (try stdio.process.vtable.write(stdio.process.context, slot.arena, line)) |why| return slot.fail(.{ .connection_lost = why });
    }

    fn request(context: *anyopaque, slot: *Slot, message: jsonrpc.Request, _: transport_.Sending) Error!transport_.Exchange {
        const stdio = of(context);
        const exchange = try stdio.gpa.create(Exchange);
        errdefer stdio.gpa.destroy(exchange);
        exchange.* = .{ .stdio = stdio, .mailbox = try stdio.router.open(message.id) };
        stdio.write(slot, .{ .request = message }) catch |err| {
            Exchange.closeOf(exchange);
            return err;
        };
        return .{ .context = exchange, .vtable = &.{ .next = Exchange.next, .cancel = Exchange.cancel, .close = Exchange.closeOf } };
    }

    fn send(context: *anyopaque, slot: *Slot, message: jsonrpc.Message) Error!void {
        return of(context).write(slot, message);
    }

    fn receive(context: *anyopaque, slot: *Slot, wait_ms: ?u64) Error!Incoming {
        return of(context).router.receive(slot, wait_ms);
    }

    fn negotiated(_: *anyopaque, _: []const u8, _: protocol.Era) void {}

    fn isClosed(context: *anyopaque) bool {
        return of(context).router.isClosed();
    }

    /// Ends the server — its input closed, then, past its while, killed — waits for its end, and lets the transport
    /// go.
    fn close(context: *anyopaque) void {
        const stdio = of(context);
        stdio.closing.store(true, .release);
        stdio.process.vtable.closeInput(stdio.process.context);
        if (!stdio.router.waitClosed(stdio.shutdown_ms)) stdio.process.vtable.kill(stdio.process.context);
        if (stdio.reading) |*reading| reading.await(stdio.host.io);
        stdio.reading = null;
        stdio.let();
    }

    /// Lets go of the process and all else the transport holds, nothing reading it.
    fn let(stdio: *Stdio) void {
        stdio.process.vtable.release(stdio.process.context);
        stdio.router.shut(null);
        stdio.router.deinit();
        stdio.gpa.destroy(stdio);
    }
};

/// Ends `process` and lets it go, once it read to its end, where no transport takes it.
fn discard(gpa: Allocator, process: Process) void {
    process.vtable.kill(process.context);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    while (true) {
        _ = arena_state.reset(.retain_capacity);
        const read = process.vtable.read(process.context, arena_state.allocator()) catch break;
        if (read == .ended) break;
    }
    process.vtable.release(process.context);
}

const Exchange = struct {
    stdio: *Stdio,
    mailbox: *router_.Mailbox,

    fn of(context: *anyopaque) *Exchange {
        return @ptrCast(@alignCast(context));
    }

    fn next(context: *anyopaque, slot: *Slot, wait_ms: ?u64) Error!Incoming {
        const exchange = Exchange.of(context);
        return exchange.stdio.router.next(exchange.mailbox, slot, wait_ms);
    }

    /// Cancels with `notifications/cancelled`.
    fn cancel(context: *anyopaque, reason: []const u8) void {
        const exchange = Exchange.of(context);
        var scratch: std.heap.ArenaAllocator = .init(exchange.stdio.gpa);
        defer scratch.deinit();
        var slot: Slot = .{ .arena = scratch.allocator() };
        if (transport_.cancelledNotification(scratch.allocator(), exchange.mailbox.id, reason)) |cancelled| {
            exchange.stdio.write(&slot, cancelled) catch {};
        } else |_| {}
        closeOf(context);
    }

    fn closeOf(context: *anyopaque) void {
        const exchange = Exchange.of(context);
        exchange.stdio.router.close(exchange.mailbox);
        exchange.stdio.gpa.destroy(exchange);
    }
};

/// Takes each line a server writes to its stderr: its logs.
pub const Lines = struct {
    context: *anyopaque,
    line: *const fn (context: *anyopaque, text: []const u8) void,
};

/// A server run as a child of this process, with exactly the environment it is given, its stderr given line by line
/// to the caller or dropped.
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
        }) catch return slot.fail(.{ .connection_lost = try std.fmt.allocPrint(slot.arena, "Could not start the MCP server {s}", .{options.command}) });
        made.* = .{ .gpa = gpa, .io = io, .child = child, .command = command, .stderr = options.stderr };
        made.output = made.child.stdout.?.readerStreaming(io, &made.buffer);
        if (options.stderr != null) made.logging = io.concurrent(readStderr, .{made}) catch null;
        return made;
    }

    pub fn process(child: *Child) Process {
        return .{ .context = child, .vtable = &.{ .write = write, .read = read, .closeInput = closeInput, .kill = kill, .release = release } };
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
        const term = child.child.wait(child.io) catch return std.fmt.allocPrint(arena, "the MCP server {s} ended", .{child.command});
        return switch (term) {
            .exited => |code| std.fmt.allocPrint(arena, "the MCP server {s} exited with {d}", .{ child.command, code }),
            else => std.fmt.allocPrint(arena, "the MCP server {s} ended", .{child.command}),
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

    fn closeInput(context: *anyopaque) void {
        const child = of(context);
        child.input.lockUncancelable(child.io);
        defer child.input.unlock(child.io);
        if (child.child.stdin) |stdin| stdin.close(child.io);
        child.child.stdin = null;
    }

    /// Kills the child, never waiting: its end is the reader's to wait for.
    fn kill(context: *anyopaque) void {
        const child = of(context);
        const id = child.child.id orelse return;
        if (builtin.os.tag == .windows) {
            _ = std.os.windows.ntdll.NtTerminateProcess(id, @fromBackingInt(1));
        } else std.posix.kill(id, .KILL) catch {};
    }

    fn release(context: *anyopaque) void {
        const child = of(context);
        child.gpa.free(child.command);
        child.gpa.destroy(child);
    }
};
