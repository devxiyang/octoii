//! The order of Siphon's parts, checked: every import between them goes down the order, never up or across, and through
//! the part's own file alone — its interface — never into the files beneath it, which are its own to move. A part is a
//! directory of `src/` with its file of the same name, or that file alone; what is at the top of `src/` in no part —
//! Siphon put together, the package's root, the test host and the tests — may import anything.
const std = @import("std");

/// The parts, each on those before it alone: the binding to Beak; images fitted, the shell's language read and text, on none; the runtime, Siphon's kernel; the threads; the
/// settings a person sets; the machine a thread works on; the threads' terminals on it; the repositories on it, as git
/// tells of them; the browser of the threads' pages; the script engine, on none of them; the tools; the agent; the
/// protocol its clients speak.
const Part = enum { beak, image, shell, text, runtime, threads, settings, machine, terminals, git, browser, script, tools, agent, protocol };

/// The part a path under `src/` belongs to; null for what is at its top, which may import anything.
fn partOf(path: []const u8) ?Part {
    const first = path[0 .. std.mem.indexOfScalar(u8, path, '/') orelse path.len];
    const name = if (std.mem.endsWith(u8, first, ".zig")) first[0 .. first.len - 4] else first;
    return std.meta.stringToEnum(Part, name);
}

test "every import between Siphon's parts goes down their order, through the part's own file" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer src.close(io);
    var walker = try src.walk(a);
    defer walker.deinit();
    var wrong: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try a.dupe(u8, entry.path);
        const from = partOf(path) orelse continue;
        const source = try src.readFileAlloc(io, path, a, .limited(4 << 20));
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, source, at, "@import(\"")) |found| {
            at = found + 9;
            const end = std.mem.indexOfScalarPos(u8, source, at, '"') orelse break;
            const imported = source[at..end];
            if (!std.mem.endsWith(u8, imported, ".zig")) continue;
            const target = try std.fs.path.resolvePosix(a, &.{ std.fs.path.dirnamePosix(path) orelse "", imported });
            const to = partOf(target) orelse {
                try wrong.append(a, try std.fmt.allocPrint(a, "{s} imports {s}, above every part", .{ path, target }));
                continue;
            };
            if (to == from) continue;
            if (@backingInt(to) > @backingInt(from)) try wrong.append(a, try std.fmt.allocPrint(a, "{s} imports {s}, a part above it", .{ path, target }));
            if (std.mem.indexOfScalar(u8, target, '/') != null) try wrong.append(a, try std.fmt.allocPrint(a, "{s} reaches into {s}, past its part's own file", .{ path, target }));
        }
    }
    for (wrong.items) |each| std.debug.print("layers: {s}\n", .{each});
    try std.testing.expectEqual(@as(usize, 0), wrong.items.len);
}
