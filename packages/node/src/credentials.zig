//! The providers' credentials, as the node keeps them in its Home: a file for each provider in the folder of them,
//! readable by the person alone, written whole at once — a key a client set, a sign-in kept and renewed — and, for a
//! provider with none there, the key the login environment holds under the variable the provider names, as before. One
//! change of a provider's credential at a time; a change of one never waits on another's, as a sign-in renews over the
//! network within its change.
const Credentials = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const siphon_ = @import("siphon");
const ai = siphon_.ai;
const foundation = siphon_.foundation;
const providers = @import("providers.zig");

gpa: Allocator,
io: Io,
/// The folder of the providers' files, by its absolute path.
folder: []const u8,
/// The login environment, the keys of providers with none kept.
environ: *const std.process.Environ.Map,
/// Guards `changing`, as a provider's lock is found or made.
lock: Io.Mutex = .init,
/// Each provider's lock, held through a change of its credential, made as its first change comes.
changing: std.StringHashMapUnmanaged(*Io.Mutex) = .empty,

pub fn deinit(store: *Credentials) void {
    var it = store.changing.iterator();
    while (it.next()) |entry| {
        store.gpa.free(entry.key_ptr.*);
        store.gpa.destroy(entry.value_ptr.*);
    }
    store.changing.deinit(store.gpa);
}

pub fn credentials(store: *Credentials) ai.driver.Credentials {
    return .{ .context = store, .vtable = &.{ .read = read, .modify = modify, .remove = remove } };
}

fn of(context: *anyopaque) *Credentials {
    return @ptrCast(@alignCast(context));
}

fn read(context: *anyopaque, arena: Allocator, provider: []const u8) error{ Unavailable, OutOfMemory }!?ai.driver.Credential {
    const store = of(context);
    if (try store.kept(arena, provider)) |credential| return credential;
    const variable = providers.keyVariable(provider) orelse return null;
    const key = store.environ.get(variable) orelse return null;
    return .{ .api_key = try arena.dupe(u8, key) };
}

/// The credential the folder keeps for `provider`; null where it keeps none, or `provider` names no file.
fn kept(store: *Credentials, arena: Allocator, provider: []const u8) error{ Unavailable, OutOfMemory }!?ai.driver.Credential {
    const path = try store.pathOf(arena, provider) orelse return null;
    const text = Io.Dir.cwd().readFileAlloc(store.io, path, arena, .limited(file_bytes_max)) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unavailable,
    };
    return foundation.json.decode(ai.driver.Credential, arena, text) catch error.Unavailable;
}

/// The most a provider's file holds.
const file_bytes_max = 64 << 10;

fn modify(context: *anyopaque, arena: Allocator, provider: []const u8, change: ai.driver.Credentials.Change) ai.driver.Credentials.ModifyError!?ai.driver.Credential {
    const store = of(context);
    const path = try store.pathOf(arena, provider) orelse return error.Unavailable;
    const held = try store.lockOf(provider);
    held.lockUncancelable(store.io);
    defer held.unlock(store.io);
    const current = try read(context, arena, provider);
    const applied = change.apply(change.context, arena, current) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Failed,
    };
    const changed = applied orelse return current;
    try store.write(arena, path, changed);
    return changed;
}

/// Writes `credential` to the file at `path` whole, as a new file renamed over it, readable by the person alone.
fn write(store: *Credentials, arena: Allocator, path: []const u8, credential: ai.driver.Credential) error{ Unavailable, OutOfMemory }!void {
    const text = try foundation.json.encode(arena, credential);
    const fresh = try std.mem.concat(arena, u8, &.{ path, ".new" });
    const owner_only: Io.File.Permissions = if (@hasDecl(Io.File.Permissions, "fromMode")) .fromMode(0o600) else .default_file;
    Io.Dir.cwd().writeFile(store.io, .{ .sub_path = fresh, .data = text, .flags = .{ .permissions = owner_only } }) catch return error.Unavailable;
    Io.Dir.rename(Io.Dir.cwd(), fresh, Io.Dir.cwd(), path, store.io) catch return error.Unavailable;
}

fn remove(context: *anyopaque, provider: []const u8) error{Unavailable}!void {
    const store = of(context);
    var buffer: [256]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    const path = (store.pathOf(fixed.allocator(), provider) catch return error.Unavailable) orelse return error.Unavailable;
    const held = store.lockOf(provider) catch return error.Unavailable;
    held.lockUncancelable(store.io);
    defer held.unlock(store.io);
    Io.Dir.cwd().deleteFile(store.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return error.Unavailable,
    };
}

/// The file of `provider`'s credential; null for a name no file is named by — one of lowercase letters, digits, dots,
/// dashes and underscores, as every provider's id is, and no dot first.
fn pathOf(store: *const Credentials, arena: Allocator, provider: []const u8) Allocator.Error!?[]const u8 {
    if (provider.len == 0 or provider.len > 64 or provider[0] == '.') return null;
    for (provider) |char| if (!(std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '.' or char == '-' or char == '_')) return null;
    return try std.fs.path.join(arena, &.{ store.folder, try std.mem.concat(arena, u8, &.{ provider, ".json" }) });
}

/// The lock of `provider`'s changes, made as its first change comes.
fn lockOf(store: *Credentials, provider: []const u8) Allocator.Error!*Io.Mutex {
    store.lock.lockUncancelable(store.io);
    defer store.lock.unlock(store.io);
    const slot = try store.changing.getOrPut(store.gpa, provider);
    if (slot.found_existing) return slot.value_ptr.*;
    errdefer store.changing.removeByPtr(slot.key_ptr);
    const made = try store.gpa.create(Io.Mutex);
    errdefer store.gpa.destroy(made);
    made.* = .init;
    slot.key_ptr.* = try store.gpa.dupe(u8, provider);
    slot.value_ptr.* = made;
    return made;
}

/// A change that sets the credential to `credential`, whatever it was.
const Setting = struct {
    credential: ai.driver.Credential,

    fn change(setting: *Setting) ai.driver.Credentials.Change {
        return .{ .context = setting, .apply = apply };
    }

    fn apply(context: *anyopaque, _: Allocator, _: ?ai.driver.Credential) ai.failure.Error!?ai.driver.Credential {
        const setting: *Setting = @ptrCast(@alignCast(context));
        return setting.credential;
    }
};

test "a key set is kept in the provider's file, the person's alone, read before the environment's, and forgotten as removed" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("OPENROUTER_API_KEY", "from-environment");
    var store: Credentials = .{ .gpa = std.testing.allocator, .io = std.testing.io, .folder = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena), .environ = &environ };
    defer store.deinit();
    const credentials_ = store.credentials();
    try std.testing.expectEqualStrings("from-environment", (try credentials_.read(arena, "openrouter")).?.api_key);
    var setting: Setting = .{ .credential = .{ .api_key = "kept" } };
    _ = try credentials_.modify(arena, "openrouter", setting.change());
    try std.testing.expectEqualStrings("kept", (try credentials_.read(arena, "openrouter")).?.api_key);
    const stat = try tmp.dir.statFile(std.testing.io, "openrouter.json", .{});
    if (@hasDecl(Io.File.Permissions, "toMode")) try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
    try credentials_.remove("openrouter");
    try std.testing.expectEqualStrings("from-environment", (try credentials_.read(arena, "openrouter")).?.api_key);
    // A name no provider has names no file: nothing kept, nothing changed.
    try std.testing.expect(try credentials_.read(arena, "../escape") == null);
    try std.testing.expectError(error.Unavailable, credentials_.modify(arena, "../escape", setting.change()));
}
