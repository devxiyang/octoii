//! The programs a task runs on the machine to their end: their output taken whole, their errors kept, their code told;
//! and those that write too much, run too long, are cut off by a stop, or are not on the machine at all.
const std = @import("std");
const h = @import("beak.zig").h;
const Machine = @import("machine.zig");
const Waits = @import("runtime.zig").Waits;
const testing = @import("testing.zig");

/// The local machine, opened for a test, whose paths start at the root.
fn openForTest() !Machine {
    return Machine.open(.{ .handle = try testing.openLocalMachine() }, .{ .base = .{ .workspace = Machine.root, .home = null } });
}

fn closeForTest(machine: Machine) void {
    machine.close();
    _ = h.beak_close(machine.handle);
}

test "the folder a thread that names none works in is octoii under the home folder, made once and kept" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const handle = try testing.openLocalMachine();
    defer _ = h.beak_close(handle);
    const host: Machine.Host = .{ .handle = handle, .home = root };
    const folder = (try Machine.defaultWorkspace(host, arena)).?;
    try std.testing.expectEqualStrings(try std.fs.path.join(arena, &.{ root, "octoii" }), folder);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "octoii/kept", .data = "kept" });
    try std.testing.expectEqualStrings(folder, (try Machine.defaultWorkspace(host, arena)).?);
    try tmp.dir.access(std.testing.io, "octoii/kept", .{});
    try std.testing.expectEqual(@as(?[]const u8, null), try Machine.defaultWorkspace(.{ .handle = handle }, arena));
    try std.testing.expectEqual(@as(?[]const u8, null), try Machine.defaultWorkspace(.{ .home = root }, arena));
}

test "a program runs to its end: its output taken whole, its errors kept, its code told" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const machine = try openForTest();
    defer closeForTest(machine);
    var waits: Waits = .{};
    defer waits.close();
    const program: Machine.Program = .{ .argv = &.{ "/bin/sh", "-c", "printf '%s' \"$GREETING\"; head -c 300000 /dev/zero | tr '\\0' x; echo oops >&2; exit 3" }, .cwd = "/", .variables = &.{.{ .name = "GREETING", .value = "hello" }} };
    const ran = try machine.run(std.testing.io, arena_allocator.allocator(), &waits, program);
    try std.testing.expectEqual(Machine.Exit{ .code = 3 }, ran.ended);
    try std.testing.expectEqual(@as(usize, 300_005), ran.output.len);
    try std.testing.expect(std.mem.startsWith(u8, ran.output, "hellox"));
    try std.testing.expectEqualStrings("oops\n", ran.errors);
}

test "a program that writes more than is taken, runs past its time, or is cut off by a stop is ended; one the machine lacks is refused" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const io = std.testing.io;
    const machine = try openForTest();
    defer closeForTest(machine);
    var waits: Waits = .{};
    defer waits.close();
    try std.testing.expectError(error.OutputTooLarge, machine.run(io, arena, &waits, .{ .argv = &.{"yes"}, .cwd = "/", .output_max = 4096 }));
    const began = std.Io.Clock.awake.now(io).toMilliseconds();
    try std.testing.expectError(error.TimedOut, machine.run(io, arena, &waits, .{ .argv = &.{ "sleep", "30" }, .cwd = "/", .timeout_ms = 100 }));
    try std.testing.expectError(error.MissingProgram, machine.run(io, arena, &waits, .{ .argv = &.{"no-such-program-anywhere"}, .cwd = "/" }));
    const Stopper = struct {
        fn run(stopping: *Waits) void {
            std.Io.sleep(std.testing.io, .fromMilliseconds(50), .awake) catch {};
            stopping.stop();
        }
    };
    var stopper = try io.concurrent(Stopper.run, .{&waits});
    defer stopper.await(io);
    try std.testing.expectError(error.Canceled, machine.run(io, arena, &waits, .{ .argv = &.{ "sleep", "30" }, .cwd = "/" }));
    try std.testing.expect(std.Io.Clock.awake.now(io).toMilliseconds() - began < 5_000);
}
