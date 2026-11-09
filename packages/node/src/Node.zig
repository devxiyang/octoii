//! Siphon on this computer's platform: the Home, the local machine and its temporary folders, the providers'
//! credentials kept in the Home and the login environment, the access its clients hold, kept in the Home, the node's
//! identity, made once and kept in the Home, the catalogue of models fetched last, kept in the Home, and Siphon opened
//! over them — what the node keeps for itself in the Home
//! hidden from the machine as Siphon reaches it, the threads shown in it, and a provider's sign-in coming back to the
//! node's own address.
const Node = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const siphon_ = @import("siphon");
const Siphon = siphon_.Siphon;
const h = siphon_.beak.h;
const Identity = @import("tunnel").Identity;
const providers = @import("providers.zig");
const Credentials = @import("credentials.zig");
const Home = @import("Home.zig");
const Access = @import("Access.zig");
const Catalogue = @import("catalogue.zig");

home: Home,
machine: h.beak_handle,
credentials: Credentials,
access: Access,
/// The key the node's tunnel sessions show, which devices reach it by.
identity: Identity,
catalogue: Catalogue,
siphon: *Siphon,

/// How the node serves its clients: the port it listens on, on this machine's loopback, where a provider's sign-in
/// comes back; and where a newer catalogue of models is served, none for the bundled one alone.
pub const Serving = struct { port: u16, catalogue: ?[]const u8 = null };

/// Where a sign-in sends the browser back to: the node's own address, which serves its app.
const sign_in_path = "/auth/callback";

/// Opens the node in `arena`, which it lives in, unmoved; Siphon's state on `gpa`, the providers' credentials kept
/// in the Home, a key of the login environment `environ` for a provider with none kept.
pub fn open(gpa: Allocator, io: std.Io, environ: *const std.process.Environ.Map, arena: Allocator, home_given: ?[]const u8, serving: Serving) !*Node {
    const node = try arena.create(Node);
    node.home = try Home.open(io, environ, arena, home_given);
    node.machine = try node.home.openMachine(arena);
    errdefer _ = h.beak_close(node.machine);
    node.credentials = .{ .gpa = gpa, .io = io, .folder = node.home.credentials, .environ = environ };
    errdefer node.credentials.deinit();
    node.access = try Access.open(io, arena, node.home.access);
    node.identity = try identityOf(io, arena, node.home.identity);
    node.catalogue = .{ .io = io, .path = node.home.catalogue };
    node.siphon = try Siphon.open(gpa, .{
        .io = io,
        .device = .{ .directory = node.home.volume },
        .credentials = node.credentials.credentials(),
        .access = node.access.interface(),
        .machine = node.machine,
        .machine_name = try Home.machineNameOf(arena, environ),
        .home = environ.get("HOME"),
        .shell = environ.get("SHELL"),
        .excludes = try Home.excludesOf(io, arena, environ),
        .browser = try Home.browserOf(io, arena, environ),
        .browser_profile = node.home.browser,
        .temporary = try Home.temporaryOf(arena, environ),
        .hidden = node.home.hidden,
        .threads = node.home.threads,
        .sandboxes = Home.machine_sandboxes,
        .outputs = node.home.outputs,
        .instructions = node.home.instructions,
        .skills = node.home.skills,
        .mcp = node.home.mcp,
        .sign_in_redirect = try arena.print("http://127.0.0.1:{d}{s}", .{ serving.port, sign_in_path }),
    }, .{
        .providers = &providers.all,
        .catalogue = if (serving.catalogue) |url| .{ .url = url, .store = node.catalogue.store() } else null,
    });
    return node;
}

/// The identity whose seed the file at `path` keeps, as hex: one made and kept there, the person's alone, where there is
/// none, as an SSH server makes its host key once.
pub fn identityOf(io: std.Io, arena: Allocator, path: []const u8) !Identity {
    const kept = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256)) catch |err| switch (err) {
        error.FileNotFound => {
            const made = Identity.generate(io);
            const hex = std.fmt.bytesToHex(made.seed(), .lower);
            try Access.writeOwnerOnly(io, path, try std.mem.concat(arena, u8, &.{ &hex, "\n" }));
            return made;
        },
        else => return err,
    };
    var seed: [Identity.seed_length]u8 = undefined;
    const hex = std.mem.trim(u8, kept, " \t\r\n");
    if (hex.len != 2 * seed.len) return error.InvalidIdentity;
    _ = std.fmt.hexToBytes(&seed, hex) catch return error.InvalidIdentity;
    return Identity.fromSeed(seed) catch error.InvalidIdentity;
}

pub fn close(node: *Node) void {
    node.siphon.close();
    node.credentials.deinit();
    _ = h.beak_close(node.machine);
}

/// Opens a node in the Home at `home` with `gpa`, and closes it.
fn openNode(gpa: Allocator, home: []const u8) !void {
    var arena_allocator: std.heap.ArenaAllocator = .init(gpa);
    defer arena_allocator.deinit();
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    const node = try Node.open(gpa, std.testing.io, &environ, arena_allocator.allocator(), home, .{ .port = 7600 });
    node.close();
}

test "a node frees what it took where an allocation fails as it opens" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    try siphon_.foundation.testing.checkAllAllocationFailures(openNode, .{home});
}

test "a node's identity is made once and kept: opened again, the node shows the same key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const path = try std.fs.path.join(arena, &.{ try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena), "identity" });
    const made = try identityOf(std.testing.io, arena, path);
    const kept = try identityOf(std.testing.io, arena, path);
    try std.testing.expect(made.publicKey().eql(kept.publicKey()));
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "not a seed" });
    try std.testing.expectError(error.InvalidIdentity, identityOf(std.testing.io, arena, path));
}
