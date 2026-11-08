//! The settings a person sets: the environment's, which every client of it shares and the runtime reads — the mode a
//! new thread starts in, the models the person starred, and the model that judges a thread's calls in auto — and each
//! device's, a document its client keeps here by the
//! session it holds, as a home folder keeps each program's own files: the client's own words, of which the runtime reads
//! none. Both are files under `siphon.settings`, each change one commit, so whoever watches them hears of it as the
//! journal tells of the commit.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const beak = @import("beak.zig");
const runtime_ = @import("runtime.zig");
const Runtime = runtime_.Runtime;
const Changes = runtime_.Changes;
const threads = @import("threads.zig");

/// The directory the settings are kept in.
pub const kind = "siphon.settings";

/// The environment's settings: the mode a thread starts in where it is made with none; the models the person starred,
/// by their references; and the model that judges calls in auto, by its reference, none where the person named none —
/// and with none, no call is let go in auto without the person.
pub const Environment = struct {
    thread_mode: threads.Mode = threads.default_mode,
    favorite_models: []const []const u8 = &.{},
    review_model: ?[]const u8 = null,
};

/// A change of the environment's settings: each setting given in place of the one it had; the review model let go
/// where it is given empty.
pub const EnvironmentChange = struct {
    thread_mode: ?threads.Mode = null,
    favorite_models: ?[]const []const u8 = null,
    review_model: ?[]const u8 = null,
};

/// A change of the settings: the environment's, and the device's — each of its names given its value, or let go where
/// it is given null.
pub const Change = struct { environment: ?EnvironmentChange = null, device: ?foundation.json.Raw = null };

/// The most bytes a device's settings may hold.
pub const device_bytes_max = 64 * 1024;

/// Where the environment's settings are kept, and the folder of each device's.
const environment_path = kind ++ "/environment.json";
const devices_path = kind ++ "/devices";

/// The environment's settings: the defaults where none was set.
pub fn environmentOf(volume: beak.Volume, arena: *const Allocator) !Environment {
    const text = volume.readAll(arena, environment_path) catch |err| switch (err) {
        error.NotFound => return .{},
        else => return err,
    };
    return foundation.json.decode(Environment, arena.*, text);
}

/// The settings of the device that holds `session`: an object of the names its client set, empty where it set none.
pub fn deviceOf(volume: beak.Volume, arena: *const Allocator, session: []const u8) !foundation.json.Raw {
    const text = volume.readAll(arena, try devicePath(arena.*, session)) catch |err| switch (err) {
        error.NotFound => return .{ .text = "{}" },
        else => return err,
    };
    return .{ .text = text };
}

fn devicePath(arena: Allocator, session: []const u8) ![]const u8 {
    if (session.len == 0 or std.mem.indexOfAny(u8, session, "/\\") != null or std.mem.eql(u8, session, "..")) return error.InvalidSession;
    return std.mem.concat(arena, u8, &.{ devices_path, "/", session, ".json" });
}

/// Sets what `change` sets — the environment's settings, and the settings of the device that holds `session` — in one
/// commit; a device's change that is not an object of names, or that would hold more than `device_bytes_max`, is
/// refused, as is a change of nothing.
pub fn set(runtime: *Runtime, arena: Allocator, session: []const u8, change: Change) !void {
    if (change.environment == null and change.device == null) return error.NothingChanged;
    var changes: Changes = .{ .arena = arena };
    try changes.mkdir(kind);
    if (change.environment) |given| {
        var environment = try environmentOf(runtime.volume, &arena);
        if (given.thread_mode) |mode| environment.thread_mode = mode;
        if (given.favorite_models) |models| environment.favorite_models = models;
        if (given.review_model) |model| environment.review_model = if (model.len == 0) null else model;
        try changes.write(environment_path, try foundation.json.encode(arena, environment));
    }
    if (change.device) |given| {
        const merged = try merge(arena, (try deviceOf(runtime.volume, &arena, session)).text, given.text);
        if (merged.len > device_bytes_max) return error.SettingsTooLarge;
        try changes.mkdir(devices_path);
        try changes.write(try devicePath(arena, session), merged);
    }
    _ = try runtime.commit(&changes);
}

/// Lets go of the settings of the device that held `session`, with `changes`, where it set any.
pub fn forget(runtime: *const Runtime, changes: *Changes, arena: Allocator, session: []const u8) !void {
    const path = try devicePath(arena, session);
    if (try runtime.volume.stat(&arena, path) == null) return;
    try changes.delete(path);
}

/// The object `kept` with each name of `given` set to its value, or let go where it is null.
fn merge(arena: Allocator, kept: []const u8, given: []const u8) ![]const u8 {
    var into = try std.json.parseFromSliceLeaky(std.json.Value, arena, kept, .{});
    const changed = try std.json.parseFromSliceLeaky(std.json.Value, arena, given, .{});
    if (into != .object) into = .{ .object = .empty };
    if (changed != .object) return error.NotAnObject;
    var names = changed.object.iterator();
    while (names.next()) |each| {
        if (each.value_ptr.* == .null) {
            _ = into.object.orderedRemove(each.key_ptr.*);
        } else try into.object.put(arena, each.key_ptr.*, each.value_ptr.*);
    }
    return foundation.json.encode(arena, into);
}

test "a device's settings take each name given, let go of each given null, and stay an object" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const first = try merge(arena, "{}", "{\"theme\":\"dark\",\"chat_width\":\"wide\"}");
    const second = try merge(arena, first, "{\"theme\":null,\"palette\":\"kelp\"}");
    const read = try std.json.parseFromSliceLeaky(std.json.Value, arena, second, .{});
    try std.testing.expect(read.object.get("theme") == null);
    try std.testing.expectEqualStrings("wide", read.object.get("chat_width").?.string);
    try std.testing.expectEqualStrings("kelp", read.object.get("palette").?.string);
    try std.testing.expectError(error.NotAnObject, merge(arena, "{}", "[1]"));
    try std.testing.expectError(error.InvalidSession, devicePath(arena, "../environment"));
}
