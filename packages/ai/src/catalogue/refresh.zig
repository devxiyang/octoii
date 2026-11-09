//! A newer catalogue: the document the host's store kept, then the one at the host's address, asked for with the kept
//! one's `ETag` and `Last-Modified`. No failure of the network, the store or the document breaks it: where one fails,
//! the catalogue stays as it was. What comes is the host's to make a new `Models` of.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const Model = @import("model.zig").Model;
const version = @import("catalogue.zig").version;

/// One text the host keeps for ai across starts: the catalogue document last fetched, its address and its tags.
pub const Store = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The text last written, in `arena`; null for none, or one that cannot be read.
        read: *const fn (context: *anyopaque, arena: Allocator) ?[]const u8,
        /// Keeps `text`; a store that cannot keep it loses it at the next start, never now.
        write: *const fn (context: *anyopaque, text: []const u8) void,
    };
};

/// What the store keeps.
const Kept = struct {
    url: []const u8,
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,
    document: std.json.Value,
};

pub const Refresh = struct {
    /// Where the catalogue document of `version` is served.
    url: []const u8,
    store: Store,
    kept: ?Kept = null,
    started: bool = false,

    /// Brings the catalogue up to date: at its first run from the store, then from the address; after, from the
    /// address. The models of the document that came, in `arena`; null where none did.
    pub fn run(refresh: *Refresh, arena: Allocator, http: foundation.http.Http) Allocator.Error!?[]const Model {
        const stored = if (refresh.started) null else try refresh.fromStore(arena);
        refresh.started = true;
        return try refresh.fetched(arena, http) orelse stored;
    }

    fn fromStore(refresh: *Refresh, arena: Allocator) Allocator.Error!?[]const Model {
        // A store that cannot be read, or holds what ai did not write, holds nothing.
        const text = refresh.store.vtable.read(refresh.store.context, arena) orelse return null;
        const kept = foundation.json.decode(Kept, arena, text) catch return null;
        if (!std.mem.eql(u8, kept.url, refresh.url)) return null;
        const models = try documentModels(arena, kept.document) orelse return null;
        refresh.kept = kept;
        return models;
    }

    fn fetched(refresh: *Refresh, arena: Allocator, http: foundation.http.Http) Allocator.Error!?[]const Model {
        var headers: std.ArrayList(foundation.http.Header) = .empty;
        if (refresh.kept) |kept| {
            if (kept.etag) |etag| try headers.append(arena, .{ .name = "if-none-match", .value = etag });
            if (kept.last_modified) |modified| try headers.append(arena, .{ .name = "if-modified-since", .value = modified });
        }
        // The network may fail in every way; the catalogue stays as it was, and the next refresh asks again.
        const response = http.send(.{ .url = refresh.url, .headers = headers.items, .wait = .{ .head_ms = 10_000, .idle_ms = 10_000 } }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        defer response.close();
        if (response.status < 200 or response.status >= 300) return null;
        const text = response.body.allocRemaining(arena, .limited(64 << 20)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        const document = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{ .allocate = .alloc_always }) catch return null;
        const models = try documentModels(arena, document) orelse return null;
        const kept: Kept = .{ .url = refresh.url, .etag = response.header("etag"), .last_modified = response.header("last-modified"), .document = document };
        refresh.kept = kept;
        refresh.store.vtable.write(refresh.store.context, try foundation.json.encode(arena, kept));
        return models;
    }
};

/// The models of a catalogue document of `version`, one that is no model left out; null for what is no document of it.
pub fn documentModels(arena: Allocator, document: std.json.Value) Allocator.Error!?[]const Model {
    if (document != .object) return null;
    const given = document.object.get("version") orelse return null;
    if (given != .integer or given.integer != version) return null;
    const listed = document.object.get("models") orelse return null;
    if (listed != .array) return null;
    var models: std.ArrayList(Model) = .empty;
    for (listed.array.items) |each| {
        const model = foundation.json.decodeValue(Model, arena, each) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        try models.append(arena, model);
    }
    return models.items;
}

const MemoryStore = struct {
    text: ?[]const u8 = null,
    arena: Allocator,

    fn store(memory: *MemoryStore) Store {
        return .{ .context = memory, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(context: *anyopaque, _: Allocator) ?[]const u8 {
        const memory: *MemoryStore = @ptrCast(@alignCast(context));
        return memory.text;
    }

    fn write(context: *anyopaque, text: []const u8) void {
        const memory: *MemoryStore = @ptrCast(@alignCast(context));
        memory.text = memory.arena.dupe(u8, text) catch null;
    }
};

test "a catalogue comes from the store first, then from the address asked with the kept tags, and fails to nothing" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const document = "{\"version\":1,\"models\":[{\"id\":\"m\",\"name\":\"M\",\"architecture\":{\"input_modalities\":[\"text\"],\"output_modalities\":[\"text\"]},\"octoii\":{\"provider\":\"p\",\"kinds\":[\"text\"]}},{\"id\":\"broken\"}]}";
    const exchanges = try foundation.json.decode([]const foundation.replay.Exchange, arena, try arena.print(
        \\[{{"request":{{"method":"GET","url":"https://cdn.example/catalogue-v1.json"}},
        \\  "response":{{"status":200,"headers":{{"etag":"\"v2\""}},"chunks":[{f}]}}}},
        \\ {{"request":{{"method":"GET","url":"https://cdn.example/catalogue-v1.json","headers":{{"if-none-match":"\"v2\""}}}},
        \\  "response":{{"status":304}}}}]
    , .{std.json.fmt(document, .{})}));
    var replay: foundation.replay.Replay = .init(arena, exchanges);
    var memory: MemoryStore = .{ .arena = arena };
    var refresh: Refresh = .{ .url = "https://cdn.example/catalogue-v1.json", .store = memory.store() };
    const first = (try refresh.run(arena, replay.http())).?;
    try std.testing.expectEqual(@as(usize, 1), first.len);
    try std.testing.expect(memory.text != null);
    try std.testing.expectEqual(null, try refresh.run(arena, replay.http()));
    try std.testing.expectEqual(null, replay.mismatch);
    // A new start reads the kept document, and an address that fails keeps it.
    var again: Refresh = .{ .url = "https://cdn.example/catalogue-v1.json", .store = memory.store() };
    var nowhere: foundation.replay.Replay = .init(arena, &.{});
    try std.testing.expectEqualStrings("m", (try again.run(arena, nowhere.http())).?[0].id);
}
