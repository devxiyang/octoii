//! Clients of many servers, each by the key its host names it by: connected as it is first asked for and shared by
//! every task that asks after, as a host's pool of connections keeps one to each place; one whose server went away is
//! connected again as it is next asked for; a host that only reads what stands leases what is connected alone, starting
//! nothing. The host makes a key's transport as it asks, so the pool knows no transport; and it says which keys of a
//! source of them stand — the keys of one beginning alike, as the files of a
//! folder share its path — so that a client of a key that no longer does is closed once its last lease is given back.
const Pool = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Client = @import("Client.zig");
const failure_ = @import("failure.zig");
const Slot = failure_.Slot;
const Error = failure_.Error;
const transport_ = @import("transport.zig");

gpa: Allocator,
options: Client.Options,
/// Guards `entries`, which entry holds which client, and the clients' holds.
lock: Io.Mutex = .init,
/// Each key ever asked for, kept till the pool is let go.
entries: std.StringArrayHashMapUnmanaged(*Entry) = .empty,

/// A key's place in the pool: the client of its server, where one is connected. One task connects it, holding
/// `connecting`; the others asking meanwhile wait for it there.
const Entry = struct {
    connecting: Io.Mutex = .init,
    held: ?*Held = null,
};

/// A client, held by its entry while it stands there and by each lease on it; let go of as its last hold is.
const Held = struct { client: *Client, holds: u32 };

/// Makes the transport of a key's server, as the host reaches it.
pub const Maker = struct {
    context: *anyopaque,
    make: *const fn (context: *anyopaque, slot: *Slot) Error!transport_.Transport,
};

/// A client leased from the pool, given back with `release`.
pub const Lease = struct {
    pool: *Pool,
    held: *Held,

    pub fn client(leased: Lease) *Client {
        return leased.held.client;
    }

    pub fn release(leased: Lease) void {
        leased.pool.drop(leased.held);
    }
};

/// A pool whose clients connect with `options`, which outlive it.
pub fn init(gpa: Allocator, options: Client.Options) Pool {
    return .{ .gpa = gpa, .options = options };
}

/// Closes every client, once no lease is held.
pub fn deinit(pool: *Pool) void {
    for (pool.entries.keys(), pool.entries.values()) |key, entry| {
        if (entry.held) |held| pool.drop(held);
        pool.gpa.free(key);
        pool.gpa.destroy(entry);
    }
    pool.entries.deinit(pool.gpa);
}

/// The client of the server `key` names: the one connected, or, where none is or its server went away, one connected
/// now over the transport `maker` makes; or why none could be, in `arena`.
pub fn lease(pool: *Pool, arena: Allocator, key: []const u8, maker: Maker) Allocator.Error!failure_.Outcome(Lease) {
    const io = pool.options.host.io;
    const entry = try pool.entryOf(key);
    entry.connecting.lockUncancelable(io);
    defer entry.connecting.unlock(io);
    if (pool.standing(entry)) |held| return .{ .done = .{ .pool = pool, .held = held } };
    var slot: Slot = .{ .arena = arena };
    const transport = maker.make(maker.context, &slot) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => return .{ .failed = slot.failure.? },
    };
    const client = switch (try Client.connect(pool.gpa, arena, pool.options, transport)) {
        .client => |connected| connected,
        .failed => |failure| return .{ .failed = failure },
    };
    const held = pool.gpa.create(Held) catch |err| {
        client.deinit();
        return err;
    };
    // The entry's hold, and the lease's.
    held.* = .{ .client = client, .holds = 2 };
    pool.lock.lockUncancelable(io);
    defer pool.lock.unlock(io);
    entry.held = held;
    return .{ .done = .{ .pool = pool, .held = held } };
}

/// The client of the server `key` names where one is connected and its server is still there; none where none is, no
/// server started for it — as a host reads what stands without starting what does not.
pub fn leaseStanding(pool: *Pool, key: []const u8) ?Lease {
    const io = pool.options.host.io;
    pool.lock.lockUncancelable(io);
    const entry = pool.entries.get(key);
    pool.lock.unlock(io);
    const held = pool.standing(entry orelse return null) orelse return null;
    return .{ .pool = pool, .held = held };
}

/// Closes the clients of every key that begins with `prefix` but those of `keys`, each once its last lease is given
/// back: the keys of one source, which now names `keys` alone.
pub fn retain(pool: *Pool, prefix: []const u8, keys: []const []const u8) void {
    var index: usize = 0;
    while (pool.notStanding(&index, prefix, keys)) |held| pool.free(held);
}

/// From the entry at `index` on, lets each go of the client of a key that begins with `prefix` and is not among
/// `keys`: the first whose last hold that was, to close outside the lock, `index` past it; null past the last entry.
fn notStanding(pool: *Pool, index: *usize, prefix: []const u8, keys: []const []const u8) ?*Held {
    const io = pool.options.host.io;
    pool.lock.lockUncancelable(io);
    defer pool.lock.unlock(io);
    while (index.* < pool.entries.count()) {
        const at = index.*;
        index.* += 1;
        const entry = pool.entries.values()[at];
        const held = entry.held orelse continue;
        const key = pool.entries.keys()[at];
        if (!std.mem.startsWith(u8, key, prefix) or isAmong(key, keys)) continue;
        entry.held = null;
        held.holds -= 1;
        if (held.holds == 0) return held;
    }
    return null;
}

/// The entry of `key`, made where there is none.
fn entryOf(pool: *Pool, key: []const u8) Allocator.Error!*Entry {
    const io = pool.options.host.io;
    pool.lock.lockUncancelable(io);
    defer pool.lock.unlock(io);
    const slot = try pool.entries.getOrPut(pool.gpa, key);
    if (slot.found_existing) return slot.value_ptr.*;
    errdefer pool.entries.swapRemoveAt(slot.index);
    const entry = try pool.gpa.create(Entry);
    errdefer pool.gpa.destroy(entry);
    slot.key_ptr.* = try pool.gpa.dupe(u8, key);
    entry.* = .{};
    slot.value_ptr.* = entry;
    return entry;
}

/// The entry's client, held once more for a lease, where its server is still there; one gone is let go of.
fn standing(pool: *Pool, entry: *Entry) ?*Held {
    const io = pool.options.host.io;
    pool.lock.lockUncancelable(io);
    const held = entry.held orelse {
        pool.lock.unlock(io);
        return null;
    };
    if (held.client.currentState() != .closed) {
        held.holds += 1;
        pool.lock.unlock(io);
        return held;
    }
    entry.held = null;
    held.holds -= 1;
    const last = held.holds == 0;
    pool.lock.unlock(io);
    if (last) pool.free(held);
    return null;
}

/// Gives back one hold of `held`, letting it go as the last is.
fn drop(pool: *Pool, held: *Held) void {
    const io = pool.options.host.io;
    pool.lock.lockUncancelable(io);
    held.holds -= 1;
    const last = held.holds == 0;
    pool.lock.unlock(io);
    if (last) pool.free(held);
}

/// Closes the client and lets it go, outside the lock, as closing waits for its server.
fn free(pool: *Pool, held: *Held) void {
    held.client.deinit();
    pool.gpa.destroy(held);
}

fn isAmong(key: []const u8, keys: []const []const u8) bool {
    for (keys) |each| if (std.mem.eql(u8, each, key)) return true;
    return false;
}

const memory = @import("memory.zig");
const server_ = @import("testing/server.zig");
const TestHost = @import("testing/host.zig").Host;

/// Makes each transport to a fake server of its own, as a server started anew is, keeping each it made.
const Fakes = struct {
    arena: Allocator,
    host: *const transport_.Host,
    made: std.ArrayList(*server_.FakeServer) = .empty,
    pairs: std.ArrayList(*memory.Pair) = .empty,
    refuse: bool = false,

    fn maker(fakes: *Fakes) Maker {
        return .{ .context = fakes, .make = make };
    }

    fn make(context: *anyopaque, slot: *Slot) Error!transport_.Transport {
        const fakes: *Fakes = @ptrCast(@alignCast(context));
        if (fakes.refuse) return slot.fail(.{ .connection_lost = "Could not start the server" });
        const fake = try fakes.arena.create(server_.FakeServer);
        fake.* = .init(fakes.arena, .{ .eras = &.{.modern}, .tools = &.{echo} });
        const pair = try memory.Pair.init(fakes.arena, fakes.host, fake.server());
        try fakes.made.append(fakes.arena, fake);
        try fakes.pairs.append(fakes.arena, pair);
        return pair.transport();
    }

    const echo: server_.Tool = .{
        .definition = "{\"name\":\"echo\",\"inputSchema\":{\"type\":\"object\"}}",
        .call = struct {
            fn call(_: *server_.ToolCall) server_.Error!server_.Outcome {
                return .{ .result = "{\"content\":[{\"type\":\"text\",\"text\":\"echoed\"}]}" };
            }
        }.call,
    };
};

fn testOptions(host: transport_.Host) Client.Options {
    return .{ .host = host, .client = .{ .name = "test", .version = "1" }, .timeout_ms = 2000, .probe_timeout_ms = 500 };
}

test "a server is connected once, as it is first asked for, and its client shared by every lease after" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var test_host: TestHost = .{};
    const host = test_host.host();
    var fakes: Fakes = .{ .arena = arena, .host = &host };
    var pool: Pool = .init(std.testing.allocator, testOptions(host));
    defer pool.deinit();
    const first = (try pool.lease(arena, "a", fakes.maker())).done;
    const second = (try pool.lease(arena, "a", fakes.maker())).done;
    try std.testing.expectEqual(first.client(), second.client());
    const other = (try pool.lease(arena, "b", fakes.maker())).done;
    try std.testing.expect(other.client() != first.client());
    try std.testing.expectEqual(@as(usize, 2), fakes.made.items.len);
    const called = (try first.client().callTool(arena, "echo", null, .{})).done;
    try std.testing.expectEqualStrings("echoed", called.content[0].text.text);
    first.release();
    second.release();
    other.release();
}

test "a server that went away is connected again as it is next asked for, and one that cannot start says why" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var test_host: TestHost = .{};
    const host = test_host.host();
    var fakes: Fakes = .{ .arena = arena, .host = &host };
    var pool: Pool = .init(std.testing.allocator, testOptions(host));
    defer pool.deinit();
    const first = (try pool.lease(arena, "a", fakes.maker())).done;
    const gone = first.client();
    // Its server goes away, as a process that exits: the lease held still reaches the client, closed.
    (memory.Sink{ .pair = fakes.pairs.items[0] }).close();
    const again = (try pool.lease(arena, "a", fakes.maker())).done;
    try std.testing.expect(again.client() != gone);
    try std.testing.expectEqual(Client.State.closed, gone.currentState());
    first.release();
    again.release();
    fakes.refuse = true;
    const refused = try pool.lease(arena, "c", fakes.maker());
    try std.testing.expectEqualStrings("Could not start the server", refused.failed.connection_lost);
}

test "what stands is leased without starting what does not: a key never connected, or whose server went away, has none" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var test_host: TestHost = .{};
    const host = test_host.host();
    var fakes: Fakes = .{ .arena = arena, .host = &host };
    var pool: Pool = .init(std.testing.allocator, testOptions(host));
    defer pool.deinit();
    try std.testing.expect(pool.leaseStanding("a") == null);
    const first = (try pool.lease(arena, "a", fakes.maker())).done;
    first.release();
    const standing_lease = pool.leaseStanding("a").?;
    try std.testing.expectEqual(first.client(), standing_lease.client());
    standing_lease.release();
    try std.testing.expect(pool.leaseStanding("b") == null);
    try std.testing.expectEqual(@as(usize, 1), fakes.made.items.len);
    (memory.Sink{ .pair = fakes.pairs.items[0] }).close();
    try std.testing.expect(pool.leaseStanding("a") == null);
}

test "a client of a key its source no longer names is closed once its last lease is given back, another source's kept" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var test_host: TestHost = .{};
    const host = test_host.host();
    var fakes: Fakes = .{ .arena = arena, .host = &host };
    var pool: Pool = .init(std.testing.allocator, testOptions(host));
    defer pool.deinit();
    const kept = (try pool.lease(arena, "a/kept", fakes.maker())).done;
    kept.release();
    const leased = (try pool.lease(arena, "a/dropped", fakes.maker())).done;
    const other = (try pool.lease(arena, "b/other", fakes.maker())).done;
    other.release();
    pool.retain("a/", &.{"a/kept"});
    // Leased still, it is open: the lease goes on with it.
    try std.testing.expect(!fakes.made.items[1].session.ended);
    _ = (try leased.client().callTool(arena, "echo", null, .{})).done;
    leased.release();
    try std.testing.expect(fakes.made.items[1].session.ended);
    try std.testing.expect(!fakes.made.items[0].session.ended);
    try std.testing.expect(!fakes.made.items[2].session.ended);
    // Asked for again, it is connected anew.
    const anew = (try pool.lease(arena, "a/dropped", fakes.maker())).done;
    defer anew.release();
    try std.testing.expectEqual(@as(usize, 4), fakes.made.items.len);
}
