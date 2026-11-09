//! The accounts a person added of the providers the host gives: each another instance of one — a second ChatGPT
//! sign-in, another login of Claude Code's, a key of another organization — reached by the provider's driver as the
//! driver sets an added account up, its models referred to by the account's id, which the host keeps its credential
//! under. Each is a directory `siphon.account:<id>` at the volume's root, labelled with the provider it is another of,
//! `siphon.provider`, and annotated with the name the person gave it; each change one commit. The providers models are
//! reached through are the host's, then the accounts', in the order they were added; each change sets them anew, those
//! set before kept till Siphon closes, as a request made while they were set may hold them still.
//!
//! A provider's quota used up — its plan's limit, as the provider told of a request it refused — stands till it is
//! given again: a file `siphon.limits/<provider>`, which expires then, so the limit stands as long as it does, whatever
//! account the provider is, the host's own or one the person added.
const Accounts = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const ai = @import("ai");
const beak = @import("beak.zig");
const runtime_ = @import("runtime.zig");
const Runtime = runtime_.Runtime;
const Changes = runtime_.Changes;
const operations = @import("operations.zig");

/// The kind of an account's directory: `siphon.account:<id>`.
pub const kind = "siphon.account";
/// The label of the provider an account is another of, by the provider's id.
pub const provider_label = "siphon.provider";
/// The annotation of the name a person gave an account.
const name_annotation = "siphon.name";
/// The most bytes an account's name holds.
pub const name_bytes_max = 64;

gpa: Allocator,
/// The providers the host gives.
host: []const ai.driver.Provider,
/// Each set of providers made, kept till Siphon closes.
made: std.ArrayList(std.heap.ArenaAllocator) = .empty,

/// An account, as a list shows it: its id, the provider it is another of, by its id, and the name it was given.
pub const Account = struct { id: []const u8, provider: []const u8, name: []const u8 };

pub fn init(gpa: Allocator, host: []const ai.driver.Provider) Accounts {
    return .{ .gpa = gpa, .host = host };
}

pub fn deinit(accounts: *Accounts) void {
    for (accounts.made.items) |*arena| arena.deinit();
    accounts.made.deinit(accounts.gpa);
}

/// The providers models are reached through, as the volume holds the accounts now: the host's, then the accounts'.
pub fn providers(accounts: *Accounts, volume: beak.Volume) ![]const ai.driver.Provider {
    try accounts.made.ensureUnusedCapacity(accounts.gpa, 1);
    var arena_allocator: std.heap.ArenaAllocator = .init(accounts.gpa);
    errdefer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const made = try providersOf(arena, accounts.host, try list(volume, arena));
    accounts.made.appendAssumeCapacity(arena_allocator);
    return made;
}

/// Has `models` reach their providers as the volume holds the accounts now.
pub fn apply(accounts: *Accounts, volume: beak.Volume, models: *ai.Models) !void {
    try models.setProviders(try accounts.providers(volume));
}

/// The host's providers, then an instance of each account's provider, in `arena`: an account of a provider the host
/// gives no more rests till it gives it again.
pub fn providersOf(arena: Allocator, host: []const ai.driver.Provider, accounts: []const Account) Allocator.Error![]const ai.driver.Provider {
    var made: std.ArrayList(ai.driver.Provider) = .empty;
    try made.appendSlice(arena, host);
    for (accounts) |account| {
        const base = providerIn(host, account.provider) orelse continue;
        try made.append(arena, .{
            .id = account.id,
            .name = try arena.print("{s} · {s}", .{ base.name, account.name }),
            .driver = base.driver,
            .settings = if (base.driver.instance) |instance| try instance(arena, account.id, base.settings) else base.settings,
        });
    }
    return made.items;
}

fn providerIn(host: []const ai.driver.Provider, id: []const u8) ?*const ai.driver.Provider {
    for (host) |*each| if (std.mem.eql(u8, each.id, id)) return each;
    return null;
}

/// The accounts, in the order they were added, in `arena`.
pub fn list(volume: beak.Volume, arena: Allocator) ![]const Account {
    const found = try volume.list(&arena, "", kind ++ ":");
    const out = try arena.alloc(Account, found.len);
    for (found, out) |*entry, *account| {
        const name = beak.slice(entry.name);
        const directory = entry.directory orelse return error.DamagedAccount;
        account.* = .{
            .id = try arena.dupe(u8, name[kind.len + 1 ..]),
            .provider = try arena.dupe(u8, beak.labelOf(directory.*.labels, directory.*.label_count, provider_label) orelse return error.DamagedAccount),
            .name = try arena.dupe(u8, beak.annotationOf(entry, name_annotation) orelse ""),
        };
    }
    return out;
}

/// Adds an account of the host's provider `provider`, named `name`: its id. Added again under the same `operation`
/// within a day, it is the account already added.
pub fn add(accounts: *const Accounts, runtime: *Runtime, arena: Allocator, provider: []const u8, name: []const u8, operation: []const u8) ![]const u8 {
    if (providerIn(accounts.host, provider) == null) return error.UnknownProvider;
    const named = try nameOf(name);
    if (try operations.before(runtime, arena, operation, "accounts.add", null)) |done| return done.result;
    const time = runtime.now();
    const id = try arena.dupe(u8, &try runtime.volume.mint(time));
    const account = try pathOf(arena, id);
    var changes: Changes = .{ .arena = arena };
    try changes.mkdir(account);
    try changes.label(account, provider_label, provider);
    try changes.annotate(account, &.{.{ .name = name_annotation, .value = named }});
    try operations.record(&changes, operation, .{ .method = "accounts.add", .result = id }, time);
    _ = try runtime.commit(&changes);
    return id;
}

/// Gives the account `id` the name `name`.
pub fn rename(runtime: *Runtime, arena: Allocator, id: []const u8, name: []const u8) !void {
    const named = try nameOf(name);
    const account = try existing(runtime, arena, id);
    var changes: Changes = .{ .arena = arena };
    try changes.annotate(account, &.{.{ .name = name_annotation, .value = named }});
    _ = try runtime.commit(&changes);
}

/// Removes the account `id`.
pub fn remove(runtime: *Runtime, arena: Allocator, id: []const u8) !void {
    const account = try existing(runtime, arena, id);
    var changes: Changes = .{ .arena = arena };
    try changes.delete(account);
    _ = try runtime.commit(&changes);
}

/// The path of the account `id`, where there is one.
fn existing(runtime: *const Runtime, arena: Allocator, id: []const u8) ![]const u8 {
    if (id.len == 0 or std.mem.indexOfAny(u8, id, "/:\x00") != null) return error.NoSuchAccount;
    const account = try pathOf(arena, id);
    if (try runtime.volume.stat(&arena, account) == null) return error.NoSuchAccount;
    return account;
}

/// `name` as an account is named: words of 1 to 64 bytes, its spaces at either end trimmed.
fn nameOf(name: []const u8) error{InvalidName}![]const u8 {
    const named = std.mem.trim(u8, name, " \t\r\n");
    if (named.len == 0 or named.len > name_bytes_max or !std.unicode.utf8ValidateSlice(named)) return error.InvalidName;
    return named;
}

pub fn pathOf(arena: Allocator, id: []const u8) Allocator.Error![]const u8 {
    return std.mem.concat(arena, u8, &.{ kind, ":", id });
}

/// The folder of the quotas used up, a file for each provider's.
const limits = "siphon.limits";

/// A provider's quota used up: when it is given again, in milliseconds since the epoch, and how long the window it is
/// counted over lasts, in minutes, where the provider said.
pub const UsedUp = struct { reset_at_ms: i64, window_minutes: ?u32 = null };

/// A thread limited by its model's quota: the provider whose quota it is, by its id, and its quota as it stands.
pub const Limited = struct { provider: []const u8, reset_at_ms: i64, window_minutes: ?u32 = null };

/// Keeps, with `changes`, that the quota of the provider `provider` is used up as `used_up` says, till it is given again.
pub fn keepUsedUp(changes: *Changes, provider: []const u8, used_up: UsedUp) Allocator.Error!void {
    if (!isProvider(provider)) return;
    const path = try beak.join(changes.arena, limits, provider);
    try changes.mkdir(limits);
    try changes.write(path, try foundation.json.encode(changes.arena, used_up));
    try changes.expire(path, used_up.reset_at_ms);
}

/// The quota of the provider `provider`, where it is used up still at `now_ms`; null where it is not, or was given again.
pub fn usedUp(volume: beak.Volume, arena: Allocator, provider: []const u8, now_ms: i64) !?UsedUp {
    if (!isProvider(provider)) return null;
    const text = volume.readAll(&arena, try beak.join(arena, limits, provider)) catch |err| switch (err) {
        error.NotFound => return null,
        else => return err,
    };
    const used_up = try foundation.json.decode(UsedUp, arena, text);
    return if (used_up.reset_at_ms > now_ms) used_up else null;
}

/// The provider of the model a reference names, by its id: what comes before its first `/`.
pub fn providerOf(model: []const u8) []const u8 {
    return model[0 .. std.mem.indexOfScalar(u8, model, '/') orelse model.len];
}

/// Whether `provider` names a provider a file may be named by: neither empty, nor holding a slash or a NUL.
fn isProvider(provider: []const u8) bool {
    return provider.len > 0 and std.mem.indexOfAny(u8, provider, "/\x00") == null;
}

/// `ms` since the epoch as a person reads a time, to the minute, in UTC.
pub fn utcOf(arena: Allocator, ms: i64) Allocator.Error![]const u8 {
    const seconds: u64 = @intCast(@max(0, @divFloor(ms, std.time.ms_per_s)));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return std.fmt.allocPrint(arena, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC", .{ year_day.year, month_day.month.numeric(), month_day.day_index + 1, day_seconds.getHoursIntoDay(), day_seconds.getMinutesIntoHour() });
}
