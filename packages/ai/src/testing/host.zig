//! A host for tests: a clock they set, credentials and stored files held in memory, randomness from a seed, and HTTP
//! from a recording.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const driver = @import("../driver.zig");

/// The moment tests send their requests at: Thu, 29 Oct 2026 12:00:00 GMT.
pub const now_ms: i64 = 1_793_275_200_000;

/// A provider's credential the host keeps.
pub const Saved = struct { provider: []const u8, credential: driver.Credential };

pub const Host = struct {
    clock_ms: i64 = now_ms,
    /// Each provider's API key, by its id.
    keys: []const struct { provider: []const u8, key: []const u8 } = &.{},
    /// One provider's credential other than a key, such as a sign-in, which `modify` changes.
    saved: ?Saved = null,
    /// Each stored file's bytes, by its reference.
    stored: []const struct { ref: []const u8, bytes: []const u8 } = &.{},
    prng: std.Random.DefaultPrng = .init(7),

    /// The host as ai takes it, its HTTP `http`.
    pub fn host(test_host: *Host, http: foundation.http.Http) driver.Host {
        return .{
            .io = std.testing.io,
            .http = http,
            .credentials = .{ .context = test_host, .vtable = &.{ .read = readCredential, .modify = modifyCredential, .remove = removeCredential } },
            .files = .{ .context = test_host, .vtable = &.{ .read = readFile } },
            .clock = .{ .context = test_host, .vtable = &.{ .now_ms = nowMs } },
            .random = test_host.prng.random(),
            .sleeper = .{ .context = test_host, .vtable = &.{ .sleep = sleep } },
        };
    }

    fn of(context: *anyopaque) *Host {
        return @ptrCast(@alignCast(context));
    }

    fn readCredential(context: *anyopaque, _: Allocator, provider: []const u8) error{ Unavailable, OutOfMemory }!?driver.Credential {
        if (of(context).saved) |saved| if (std.mem.eql(u8, saved.provider, provider)) return saved.credential;
        for (of(context).keys) |each| if (std.mem.eql(u8, each.provider, provider)) return .{ .api_key = each.key };
        return null;
    }

    fn modifyCredential(context: *anyopaque, arena: Allocator, provider: []const u8, change: driver.Credentials.Change) driver.Credentials.ModifyError!?driver.Credential {
        const current = try readCredential(context, arena, provider);
        const changed = try change.apply(change.context, arena, current) orelse return current;
        of(context).saved = .{ .provider = provider, .credential = changed };
        return changed;
    }

    /// Forgets the credential kept for `provider`; its key, where the test gave one, is read as before.
    fn removeCredential(context: *anyopaque, provider: []const u8) error{Unavailable}!void {
        const saved = of(context).saved orelse return;
        if (std.mem.eql(u8, saved.provider, provider)) of(context).saved = null;
    }

    fn readFile(context: *anyopaque, _: Allocator, ref: []const u8) error{ NotFound, Unavailable, OutOfMemory }![]const u8 {
        for (of(context).stored) |each| if (std.mem.eql(u8, each.ref, ref)) return each.bytes;
        return error.NotFound;
    }

    /// A wait passes at once, the clock moved on by it.
    fn sleep(context: *anyopaque, ms: u64) error{Canceled}!void {
        of(context).clock_ms += @intCast(ms);
    }

    fn nowMs(context: *anyopaque) i64 {
        return of(context).clock_ms;
    }
};
