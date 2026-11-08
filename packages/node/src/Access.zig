//! The node's access: the sessions its clients hold and the links that pair new clients, each a file in the Home's
//! `access` folder, which the person alone may read — named by its id, holding the digest of its secret, never the
//! secret, or the key of the device that holds it — as an SSH server keeps its authorized keys. A client presents a
//! credential, `<id>.<secret>`: a browser in its cookie, a program as a bearer token; a device in a tunnel session is
//! known by the key its session showed. A link's credential pairs one client, once, while the link lasts: the node
//! issues that client a session granting what the link granted, held as the client holds sessions. The node's commands make links and sessions here as
//! the same person, so a running node honours a link `octoii pair` made; Siphon's access methods read, make and revoke
//! them through the node. Their ids are UUIDv7s of the node's own, as the access is the node's, not the volume's.
const Access = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const siphon_ = @import("siphon");
const foundation = siphon_.foundation;
const Protocol = siphon_.protocol.Access;
pub const Scope = Protocol.Scope;
pub const Method = Protocol.Method;
pub const all_scopes = Protocol.all_scopes;

io: Io,
/// The folder of the sessions' files.
sessions: []const u8,
/// The folder of the links' files.
links: []const u8,
/// None: the io's real clock.
clock: ?foundation.time.Clock = null,

/// How long a link pairs, from when it is made, as a one-time code lasts.
pub const link_ms: i64 = 5 * std.time.ms_per_min;
/// How long a session lasts, from when it is issued.
pub const session_ms: i64 = 30 * std.time.ms_per_day;

/// A session or a link, as its file keeps it: the digest of its secret, never the secret; or a session's device key.
const Kept = struct {
    id: []const u8,
    scopes: []const Scope,
    label: ?[]const u8 = null,
    /// A session's: how its client holds it.
    method: ?Method = null,
    /// When it was made and when it expires, in ms since the epoch.
    made_at: i64,
    expires_at: i64,
    /// The SHA-256 of its secret, in hex, for a link and a session held by its secret.
    digest: ?[]const u8 = null,
    /// The key of the device that holds the session, as text.
    key: ?[]const u8 = null,
};

/// How a session's client holds it: by its secret, in a browser's cookie or as a program's bearer token, or by the key
/// of the device its tunnel session showed.
pub const Holder = union(Method) {
    cookie,
    bearer,
    key: []const u8,
};

/// A session or a link made: its id, its credential — `<id>.<secret>`, the one time it is seen, or a device's key —
/// and when it expires.
pub const Made = struct { id: []const u8, credential: []const u8, expires_at: i64 };

/// The access kept in `folder`, its folders made where they are missing, the person's alone.
pub fn open(io: Io, arena: Allocator, folder: []const u8) !Access {
    const access: Access = .{
        .io = io,
        .sessions = try std.fs.path.join(arena, &.{ folder, "sessions" }),
        .links = try std.fs.path.join(arena, &.{ folder, "links" }),
    };
    try makeOwnerOnly(io, access.sessions);
    try makeOwnerOnly(io, access.links);
    return access;
}

/// Makes the folder at `path` where it is missing, and leaves it the person's alone, as their ~/.ssh is.
fn makeOwnerOnly(io: Io, path: []const u8) !void {
    const modes = @hasDecl(Io.File.Permissions, "fromMode");
    const owner_only: Io.File.Permissions = if (modes) .fromMode(0o700) else .default_dir;
    var dir = try Io.Dir.cwd().createDirPathOpen(io, path, .{ .permissions = owner_only });
    defer dir.close(io);
    if (modes) try dir.setPermissions(io, owner_only);
}

/// A link made that pairs one client while it lasts, granting `scopes`.
pub fn makeLink(access: Access, arena: Allocator, label: ?[]const u8, scopes: []const Scope) !Made {
    return access.make(arena, access.links, .{ .label = label, .scopes = scopes, .lasts_ms = link_ms });
}

/// A session issued outright, held as `holder` holds it, as the person issues one for a program of theirs.
pub fn issue(access: Access, arena: Allocator, holder: Holder, label: ?[]const u8, scopes: []const Scope) !Made {
    return access.make(arena, access.sessions, .{ .label = label, .scopes = scopes, .holder = holder, .lasts_ms = session_ms });
}

/// What a session or a link is made with: a session's holder, none for a link.
const Making = struct { label: ?[]const u8, scopes: []const Scope, holder: ?Holder = null, lasts_ms: i64 };

/// A session or a link made in `folder`: its file written, the person's alone, before its credential is handed out —
/// a secret's digest kept, or the key of the device that holds the session.
fn make(access: Access, arena: Allocator, folder: []const u8, making: Making) !Made {
    const now = access.nowMs();
    const id = try arena.dupe(u8, &uuid7(access.io, now));
    var kept: Kept = .{
        .id = id,
        .scopes = making.scopes,
        .label = making.label,
        .method = if (making.holder) |holder| holder else null,
        .made_at = now,
        .expires_at = now + making.lasts_ms,
    };
    const credential = if (making.holder != null and making.holder.? == .key) held: {
        kept.key = making.holder.?.key;
        break :held kept.key.?;
    } else secret: {
        var secret_bytes: [32]u8 = undefined;
        access.io.random(&secret_bytes);
        const secret = std.fmt.bytesToHex(secret_bytes, .lower);
        kept.digest = try arena.dupe(u8, &digestOf(&secret));
        break :secret try std.mem.concat(arena, u8, &.{ id, ".", &secret });
    };
    try writeOwnerOnly(access.io, try fileOf(arena, folder, id), try foundation.json.encode(arena, kept));
    return .{ .id = id, .credential = credential, .expires_at = kept.expires_at };
}

/// Pairs a client with the link `credential` names, once: a session issued for it, held as `holder` holds it, labelled
/// `label`, granting what the link granted; null where the credential pairs nothing — of no link, of another secret,
/// spent or expired. A link is spent as its file is removed: of two clients that pair with it at once, the one whose
/// removal takes the file pairs, and the other finds it gone.
pub fn redeem(access: Access, arena: Allocator, credential: []const u8, holder: Holder, label: ?[]const u8) !?Made {
    const kept = try access.find(arena, access.links, credential) orelse return null;
    Io.Dir.cwd().deleteFile(access.io, try fileOf(arena, access.links, kept.id)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (kept.expires_at <= access.nowMs()) return null;
    return try access.issue(arena, holder, label, kept.scopes);
}

/// Who `credential` names: a session of the node's that has not expired, by its id, with its scopes; null where it
/// names none.
pub fn authenticate(access: Access, arena: Allocator, credential: []const u8) !?Protocol.Principal {
    const kept = try access.find(arena, access.sessions, credential) orelse return null;
    if (kept.expires_at <= access.nowMs()) return null;
    return .{ .session = kept.id, .scopes = kept.scopes };
}

/// Who the device of `key` is: the newest session it holds that has not expired, by its id, with its scopes; null
/// where it holds none, as an SSH server finds a client's key among its authorized keys.
pub fn authenticateKey(access: Access, arena: Allocator, key: []const u8) !?Protocol.Principal {
    for (try access.keptIn(arena, access.sessions)) |kept| {
        const held = kept.key orelse continue;
        if (std.mem.eql(u8, held, key)) return .{ .session = kept.id, .scopes = kept.scopes };
    }
    return null;
}

/// The sessions and the links that pair, newest first, those that expired left out and removed.
pub fn list(access: Access, arena: Allocator) !Protocol.Listed {
    const sessions = try access.keptIn(arena, access.sessions);
    const links = try access.keptIn(arena, access.links);
    const shown_sessions = try arena.alloc(Protocol.Session, sessions.len);
    for (sessions, shown_sessions) |kept, *shown| shown.* = .{
        .id = kept.id,
        .method = kept.method orelse .bearer,
        .scopes = kept.scopes,
        .label = kept.label,
        .issued_at = kept.made_at,
        .expires_at = kept.expires_at,
    };
    const shown_links = try arena.alloc(Protocol.Link, links.len);
    for (links, shown_links) |kept, *shown| shown.* = .{ .id = kept.id, .scopes = kept.scopes, .label = kept.label, .created_at = kept.made_at, .expires_at = kept.expires_at };
    return .{ .sessions = shown_sessions, .links = shown_links };
}

/// The session or the link of `id` revoked: its file removed.
pub fn revoke(access: Access, arena: Allocator, id: []const u8) !Protocol.Revoked {
    if (!isId(id)) return .none;
    if (try removed(access.io, try fileOf(arena, access.sessions, id))) return .session;
    if (try removed(access.io, try fileOf(arena, access.links, id))) return .link;
    return .none;
}

/// Whether the file at `path` was there to remove.
fn removed(io: Io, path: []const u8) !bool {
    Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

/// What `folder` keeps, newest first: what expired is left out and removed.
fn keptIn(access: Access, arena: Allocator, folder: []const u8) ![]const Kept {
    var dir = try Io.Dir.cwd().openDir(access.io, folder, .{ .iterate = true });
    defer dir.close(access.io);
    var found: std.ArrayList(Kept) = .empty;
    var entries = dir.iterate();
    const now = access.nowMs();
    while (try entries.next(access.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, file_extension)) continue;
        const text = dir.readFileAlloc(access.io, entry.name, arena, .limited(file_bytes_max)) catch continue;
        const kept = foundation.json.decode(Kept, arena, text) catch continue;
        if (kept.expires_at <= now) {
            dir.deleteFile(access.io, entry.name) catch {};
            continue;
        }
        try found.append(arena, kept);
    }
    std.mem.sort(Kept, found.items, {}, newerFirst);
    return found.items;
}

fn newerFirst(_: void, a: Kept, b: Kept) bool {
    return std.mem.order(u8, a.id, b.id) == .gt;
}

/// What `folder` keeps of the credential `credential`: where its id names a file there and its secret is that file's.
fn find(access: Access, arena: Allocator, folder: []const u8, credential: []const u8) !?Kept {
    const dot = std.mem.indexOfScalar(u8, credential, '.') orelse return null;
    const id = credential[0..dot];
    if (!isId(id)) return null;
    const text = Io.Dir.cwd().readFileAlloc(access.io, try fileOf(arena, folder, id), arena, .limited(file_bytes_max)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const kept = foundation.json.decode(Kept, arena, text) catch return null;
    const digest = kept.digest orelse return null;
    if (digest.len != 64) return null;
    const given = digestOf(credential[dot + 1 ..]);
    if (!std.crypto.timing_safe.eql([64]u8, given, digest[0..64].*)) return null;
    return kept;
}

/// The file of `id` in `folder`.
fn fileOf(arena: Allocator, folder: []const u8, id: []const u8) ![]const u8 {
    return std.mem.concat(arena, u8, &.{ folder, std.fs.path.sep_str, id, file_extension });
}

const file_extension = ".json";

/// The largest file of a session or a link the node reads.
const file_bytes_max = 64 << 10;

/// Whether `id` is an id as the access names them, a UUID's 36 characters — so it names a file in its folder alone.
fn isId(id: []const u8) bool {
    if (id.len != 36) return false;
    for (id, 0..) |char, at| {
        const dash = at == 8 or at == 13 or at == 18 or at == 23;
        if (dash != (char == '-')) return false;
        if (!dash and !std.ascii.isHex(char)) return false;
    }
    return true;
}

/// The SHA-256 of `secret`, in hex.
fn digestOf(secret: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(secret, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// A UUIDv7 of the time `now_ms`, its other bits random.
fn uuid7(io: Io, now_ms: i64) [36]u8 {
    var bytes: [16]u8 = undefined;
    io.random(bytes[6..]);
    std.mem.writeInt(u48, bytes[0..6], @intCast(now_ms), .big);
    bytes[6] = (bytes[6] & 0x0f) | 0x70;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(bytes, .lower);
    var id: [36]u8 = undefined;
    _ = std.fmt.bufPrint(&id, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] }) catch unreachable;
    return id;
}

/// Writes `data` to the file at `path`, which the person alone may read.
pub fn writeOwnerOnly(io: Io, path: []const u8, data: []const u8) !void {
    const owner_only: Io.File.Permissions = if (@hasDecl(Io.File.Permissions, "fromMode")) .fromMode(0o600) else .default_file;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data, .flags = .{ .permissions = owner_only } });
}

/// The time on the access's clock, in ms since the epoch.
fn nowMs(access: Access) i64 {
    return foundation.time.nowMs(access.io, access.clock);
}

/// The access as Siphon reaches it: its methods read, make links in, and revoke from the folder.
pub fn interface(access: *Access) Protocol {
    return .{ .context = access, .vtable = &.{ .list = listFor, .pair = pairFor, .revoke = revokeFor } };
}

fn of(context: *anyopaque) *Access {
    return @ptrCast(@alignCast(context));
}

fn listFor(context: *anyopaque, arena: Allocator) anyerror!Protocol.Listed {
    return of(context).list(arena);
}

fn pairFor(context: *anyopaque, arena: Allocator, label: ?[]const u8, scopes: []const Scope) anyerror!Protocol.Paired {
    const made = try of(context).makeLink(arena, label, scopes);
    return .{ .id = made.id, .credential = made.credential, .expires_at = made.expires_at };
}

fn revokeFor(context: *anyopaque, arena: Allocator, id: []const u8) anyerror!Protocol.Revoked {
    return of(context).revoke(arena, id);
}

/// A clock a test sets.
const TestClock = struct {
    now_ms: i64,

    fn clock(test_clock: *TestClock) foundation.time.Clock {
        return .{ .context = test_clock, .vtable = &.{ .now_ms = nowOf } };
    }

    fn nowOf(context: *anyopaque) i64 {
        const test_clock: *TestClock = @ptrCast(@alignCast(context));
        return test_clock.now_ms;
    }
};

/// Access in a fresh folder of `tmp`'s, on `clock`.
fn testAccess(tmp: *std.testing.TmpDir, arena: Allocator, clock: *TestClock) !Access {
    const folder = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    var access = try Access.open(std.testing.io, arena, folder);
    access.clock = clock.clock();
    return access;
}

test "a link pairs one client, once, while it lasts, with a session granting what the link granted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var clock: TestClock = .{ .now_ms = 1_700_000_000_000 };
    const access = try testAccess(&tmp, arena, &clock);
    const link = try access.makeLink(arena, "phone", &.{.@"threads.read"});
    const session = (try access.redeem(arena, link.credential, .cookie, "Safari")).?;
    const principal = (try access.authenticate(arena, session.credential)).?;
    try std.testing.expectEqualStrings(session.id, principal.session);
    try std.testing.expectEqualSlices(Scope, &.{.@"threads.read"}, principal.scopes);
    // Spent, it pairs no other client.
    try std.testing.expect(try access.redeem(arena, link.credential, .cookie, null) == null);
    // One past its time pairs none, and is gone.
    const late = try access.makeLink(arena, null, Protocol.all_scopes);
    clock.now_ms += link_ms;
    try std.testing.expect(try access.redeem(arena, late.credential, .cookie, null) == null);
    try std.testing.expectEqual(@as(usize, 0), (try access.list(arena)).links.len);
}

test "a credential names its session only by its own secret, an id of its own shape, and while the session lasts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var clock: TestClock = .{ .now_ms = 1_700_000_000_000 };
    const access = try testAccess(&tmp, arena, &clock);
    const made = try access.issue(arena, .bearer, "script", Protocol.all_scopes);
    const id = made.credential[0..36];
    const zeros: [64]u8 = @splat('0');
    const forged = try std.mem.concat(arena, u8, &.{ id, ".", &zeros });
    for ([_][]const u8{ forged, id, "../links/x.y", "", "not-an-id.secret" }) |credential|
        try std.testing.expect(try access.authenticate(arena, credential) == null);
    try std.testing.expect(try access.authenticate(arena, made.credential) != null);
    clock.now_ms += session_ms;
    try std.testing.expect(try access.authenticate(arena, made.credential) == null);
}

test "the access lists its sessions and links newest first, without their secrets, and revokes each by its id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var clock: TestClock = .{ .now_ms = 1_700_000_000_000 };
    const access = try testAccess(&tmp, arena, &clock);
    const first = try access.issue(arena, .bearer, "first", Protocol.all_scopes);
    clock.now_ms += 1;
    const second = try access.issue(arena, .cookie, "second", Protocol.all_scopes);
    const link = try access.makeLink(arena, "tablet", Protocol.all_scopes);
    const listed = try access.list(arena);
    try std.testing.expectEqual(@as(usize, 2), listed.sessions.len);
    try std.testing.expectEqualStrings(second.id, listed.sessions[0].id);
    try std.testing.expectEqual(Method.cookie, listed.sessions[0].method);
    try std.testing.expectEqualStrings("tablet", listed.links[0].label.?);
    const encoded = try foundation.json.encode(arena, listed);
    try std.testing.expect(std.mem.indexOf(u8, encoded, first.credential[37..]) == null);
    try std.testing.expectEqual(Protocol.Revoked.session, try access.revoke(arena, first.id));
    try std.testing.expectEqual(Protocol.Revoked.link, try access.revoke(arena, link.id));
    try std.testing.expectEqual(Protocol.Revoked.none, try access.revoke(arena, first.id));
    try std.testing.expectEqual(Protocol.Revoked.none, try access.revoke(arena, "../token"));
    try std.testing.expect(try access.authenticate(arena, first.credential) == null);
}

test "a link pairs a device by its key: its session found by the key alone, and by no credential" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var clock: TestClock = .{ .now_ms = 1_700_000_000_000 };
    const access = try testAccess(&tmp, arena, &clock);
    const key = "abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrst";
    const link = try access.makeLink(arena, null, &.{.@"threads.read"});
    const session = (try access.redeem(arena, link.credential, .{ .key = key }, "phone")).?;
    const principal = (try access.authenticateKey(arena, key)).?;
    try std.testing.expectEqualStrings(session.id, principal.session);
    try std.testing.expectEqualSlices(Scope, &.{.@"threads.read"}, principal.scopes);
    try std.testing.expect(try access.authenticateKey(arena, "another key") == null);
    try std.testing.expect(try access.authenticate(arena, try std.mem.concat(arena, u8, &.{ session.id, ".", key })) == null);
    try std.testing.expectEqual(Method.key, (try access.list(arena)).sessions[0].method);
    clock.now_ms += session_ms;
    try std.testing.expect(try access.authenticateKey(arena, key) == null);
}
