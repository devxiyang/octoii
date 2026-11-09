//! The catalogue of models the node fetched last, kept in its Home across starts, so a node that starts with no network
//! knows what it knew: one file, written whole as a new file renamed over it.
const Catalogue = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ai = @import("siphon").ai;

io: Io,
/// The file, by its absolute path.
path: []const u8,

/// The store `ai` keeps the catalogue fetched last in.
pub fn store(catalogue: *Catalogue) ai.refresh.Store {
    return .{ .context = catalogue, .vtable = &.{ .read = read, .write = write } };
}

fn of(context: *anyopaque) *Catalogue {
    return @ptrCast(@alignCast(context));
}

/// What the file holds; none where it is missing or cannot be read, as `ai` takes it.
fn read(context: *anyopaque, arena: Allocator) ?[]const u8 {
    const catalogue = of(context);
    return Io.Dir.cwd().readFileAlloc(catalogue.io, catalogue.path, arena, .limited(64 << 20)) catch null;
}

/// Keeps `text` whole; where it cannot, the file keeps what it held, and the next start fetches anew.
fn write(context: *anyopaque, text: []const u8) void {
    const catalogue = of(context);
    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const fresh = std.fmt.bufPrint(&buffer, "{s}.new", .{catalogue.path}) catch return;
    Io.Dir.cwd().writeFile(catalogue.io, .{ .sub_path = fresh, .data = text }) catch return;
    Io.Dir.rename(Io.Dir.cwd(), fresh, Io.Dir.cwd(), catalogue.path, catalogue.io) catch return;
}

test "the catalogue kept is read back whole, and none is read where none was kept" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    var catalogue: Catalogue = .{ .io = std.testing.io, .path = try std.fs.path.join(arena, &.{ root, "catalogue.json" }) };
    const kept = catalogue.store();
    try std.testing.expect(kept.vtable.read(kept.context, arena) == null);
    kept.vtable.write(kept.context, "{\"version\":1}");
    try std.testing.expectEqualStrings("{\"version\":1}", kept.vtable.read(kept.context, arena).?);
}
