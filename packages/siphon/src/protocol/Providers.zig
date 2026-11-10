//! The providers as a client manages them: each one the node reaches models through, how it is connected — by an API
//! key, by a sign-in in a browser, or as a server of the person's, which says itself how it stands — and the kind of
//! credential the host keeps for it, never the credential; how one stands, asked of it; a sign-in begun and finished;
//! the accounts the person adds of the host's providers, renames and removes; and the providers' models listed again.
//! What goes to a provider's server or the network is done as a job, off the loop. A sign-in begun waits here, one at
//! a time and for a while, for the address the browser was sent back to.
const Providers = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ai = @import("ai");
const Connection = @import("Connection.zig");
const Waits = @import("../runtime.zig").Waits;
const Clients = @import("Clients.zig");
const Accounts = @import("../accounts.zig");
const relist = @import("../agent.zig").models.relist;

/// The address a provider's sign-in sends the browser back to — the host's own, on this machine's loopback; none where
/// the host takes none back.
redirect: ?[]const u8,
/// The sign-in begun last, waiting for the browser's return.
pending: ?Pending = null,

/// How long a sign-in begun waits for the browser's return.
const sign_in_ms = 10 * std.time.ms_per_min;

/// A sign-in begun: its provider and the attempt its end needs, held in memory of their own, and when it began.
const Pending = struct { arena_allocator: std.heap.ArenaAllocator, provider: []const u8, sign_in: ai.driver.SignIn, began_ms: i64 };

pub fn deinit(providers: *Providers) void {
    if (providers.pending) |*pending| pending.arena_allocator.deinit();
    providers.pending = null;
}

/// Keeps `begun` waiting, in place of a sign-in begun before.
fn keep(providers: *Providers, begun: Pending) void {
    providers.deinit();
    providers.pending = begun;
}

/// The sign-in that waits, taken to be finished; none where none waits, or the one that did waited too long.
fn take(providers: *Providers, now_ms: i64) ?Pending {
    const pending = providers.pending orelse return null;
    providers.pending = null;
    if (now_ms - pending.began_ms <= sign_in_ms) return pending;
    var arena_allocator = pending.arena_allocator;
    arena_allocator.deinit();
    return null;
}

/// A provider as a client is told of it: its id and name, how it is connected — through which agent, where it is — and
/// the kind of credential the host keeps for it — `api_key`, `oauth` or `none` — none where it keeps none; for an account the person added, the host's
/// provider it is another of and the name it was given; and its quota, where it is used up still.
const Listed = struct { id: []const u8, name: []const u8, connects: Accounts.Connects, through: ?[]const u8 = null, credential: ?[]const u8 = null, account: ?Added = null, used_up: ?Accounts.UsedUp = null };

/// An account the person added, as a provider listed tells of it: the host's provider it is another of, by its id, and
/// the name it was given.
const Added = struct { of: []const u8, name: []const u8 };

/// The providers, each as a client is told of it.
pub fn list(connection: *Connection, arena: Allocator, id: []const u8, _: struct {}) !void {
    const clients = connection.clients;
    const ids = try clients.models.providerIds(arena);
    const added = try Accounts.list(clients.runtime.volume, arena);
    const listed = try arena.alloc(Listed, ids.len);
    for (ids, listed) |provider_id, *each| {
        const provider = clients.models.provider(provider_id).?;
        const held = if (clients.credentials) |store| store.read(arena, provider_id) catch null else null;
        each.* = .{ .id = provider_id, .name = provider.name, .connects = Accounts.connectsOf(provider), .through = provider.driver.through, .credential = if (held) |credential| if (credential.usable()) @tagName(credential) else null else null };
        for (added) |account| if (std.mem.eql(u8, account.id, provider_id)) {
            each.account = .{ .of = account.provider, .name = account.name };
        };
        each.used_up = try Accounts.usedUp(clients.runtime.volume, arena, provider_id, clients.runtime.now());
    }
    return connection.answer(arena, id, .{ .providers = listed });
}

/// An account added of the host's provider `provider`, named `name`, once for its operation: its id. The models reach
/// it from now, and list its own off the loop, where its provider lists them.
pub fn addAccount(connection: *Connection, arena: Allocator, id: []const u8, given: struct { provider: []const u8, name: []const u8, operation: []const u8 }) !void {
    const clients = connection.clients;
    const added = try clients.accounts.add(clients.runtime, arena, given.provider, given.name, given.operation);
    try clients.accounts.apply(clients.runtime.volume, clients.models);
    relist(clients.runtime, clients.models);
    return connection.answer(arena, id, .{ .account = added });
}

/// The account `account` given the name `name`.
pub fn renameAccount(connection: *Connection, arena: Allocator, id: []const u8, given: struct { account: []const u8, name: []const u8 }) !void {
    const clients = connection.clients;
    try Accounts.rename(clients.runtime, arena, given.account, given.name);
    try clients.accounts.apply(clients.runtime.volume, clients.models);
    return connection.answer(arena, id, Connection.nothing);
}

/// The account `account` removed, and the credential the host kept for it forgotten: a thread whose model was one of
/// its models asks no model till it is given another.
pub fn removeAccount(connection: *Connection, arena: Allocator, id: []const u8, given: struct { account: []const u8 }) !void {
    const clients = connection.clients;
    // The account's provider as the providers held it, which lets go of what it keeps of the account once it is removed.
    const removed = clients.models.provider(given.account);
    try Accounts.remove(clients.runtime, arena, given.account);
    if (clients.credentials) |store| store.remove(given.account) catch {};
    try clients.accounts.apply(clients.runtime.volume, clients.models);
    if (removed) |account| clients.forgetAccount(account);
    return connection.answer(arena, id, Connection.nothing);
}

/// How a provider stands, asked of it off the loop: whether a request may reach it, who it is connected as, and what is
/// wrong.
pub fn status(connection: *Connection, _: Allocator, id: []const u8, given: Status.Given) !void {
    if (connection.clients.models.provider(given.provider) == null) return error.UnknownProvider;
    return connection.answerFromJob(id, Status, given);
}

const Status = struct {
    pub const Given = struct { provider: []const u8 };

    models: *ai.Models,
    provider: []const u8,

    pub fn of(_: Allocator, clients: *Clients, given: Given) !Status {
        return .{ .models = clients.models, .provider = given.provider };
    }

    pub fn run(work: *Status, arena: Allocator, _: *Waits) anyerror!ai.driver.Status {
        return work.models.status(arena, work.provider);
    }
};

/// The providers' models listed again, and the catalogue fetched anew where the host gives its address, off the loop: a
/// listing that fails keeps what was listed before.
pub fn refresh(connection: *Connection, _: Allocator, id: []const u8, given: Refresh.Given) !void {
    return connection.answerFromJob(id, Refresh, given);
}

const Refresh = struct {
    pub const Given = struct {};

    models: *ai.Models,

    pub fn of(_: Allocator, clients: *Clients, _: Given) !Refresh {
        return .{ .models = clients.models };
    }

    pub fn run(work: *Refresh, _: Allocator, _: *Waits) anyerror!void {
        return work.models.refresh();
    }
};

/// A sign-in to a provider begun, off the loop: where the person signs in, the attempt waiting here for the browser's
/// return in place of one begun before.
pub fn signIn(connection: *Connection, _: Allocator, id: []const u8, given: struct { provider: []const u8 }) !void {
    const clients = connection.clients;
    const provider = clients.models.provider(given.provider) orelse return error.UnknownProvider;
    if (provider.driver.sign_in == null) return error.NotSignedInTo;
    const redirect = clients.providers.redirect orelse return error.NoSignInReturn;
    return connection.answerFromJob(id, SignIn, .{ .provider = given.provider, .redirect = redirect });
}

const SignIn = struct {
    pub const Given = struct { provider: []const u8, redirect: []const u8 };

    clients: *Clients,
    redirect: []const u8,
    /// What the attempt holds, and its provider, kept past the job where it begins.
    attempt_arena: std.heap.ArenaAllocator,
    provider: []const u8,
    kept: bool = false,

    pub fn of(_: Allocator, clients: *Clients, given: Given) !SignIn {
        var attempt_arena: std.heap.ArenaAllocator = .init(clients.runtime.allocator);
        errdefer attempt_arena.deinit();
        const provider = try attempt_arena.allocator().dupe(u8, given.provider);
        return .{ .clients = clients, .redirect = given.redirect, .attempt_arena = attempt_arena, .provider = provider };
    }

    pub fn run(work: *SignIn, _: Allocator, _: *Waits) anyerror!ai.Models.SignInStarted {
        const options: ai.driver.SignInOptions = .{ .redirect_uri = work.redirect, .agent_name_hint = "Octoii" };
        return work.clients.models.signIn(work.attempt_arena.allocator(), work.provider, options);
    }

    /// Keeps the sign-in begun waiting for the browser's return, in place of one begun before, and answers where the
    /// person signs in; one the provider refused is told in its words.
    pub fn answer(work: *SignIn, arena: Allocator, connection: *Connection, id: []const u8, outcome: anyerror!ai.Models.SignInStarted) void {
        const started = outcome catch |err| return connection.refuseFailed(arena, id, err);
        const begun = switch (started) {
            .failed => |failure| return connection.refuse(arena, id, "sign-in-failed", failure.message),
            .started => |begun| begun,
        };
        work.clients.providers.keep(.{ .arena_allocator = work.attempt_arena, .provider = work.provider, .sign_in = begun, .began_ms = work.clients.runtime.now() });
        work.kept = true;
        connection.answer(arena, id, .{ .url = begun.url }) catch |err| connection.refuseFailed(arena, id, err);
    }

    pub fn deinit(work: *SignIn) void {
        if (!work.kept) work.attempt_arena.deinit();
    }
};

/// The sign-in that waits finished, off the loop, from the address the browser was sent back to — or the one the person
/// copied from its address bar — its credential kept by the host.
pub fn finishSignIn(connection: *Connection, _: Allocator, id: []const u8, given: FinishSignIn.Given) !void {
    return connection.answerFromJob(id, FinishSignIn, given);
}

const FinishSignIn = struct {
    pub const Given = struct { redirect: []const u8 };

    models: *ai.Models,
    redirect: []const u8,
    pending: Pending,

    pub fn of(_: Allocator, clients: *Clients, given: Given) !FinishSignIn {
        // Taken last, so a sign-in is lost to nothing that fails before.
        const pending = clients.providers.take(clients.runtime.now()) orelse return error.NoSignIn;
        return .{ .models = clients.models, .redirect = given.redirect, .pending = pending };
    }

    pub fn run(work: *FinishSignIn, arena: Allocator, _: *Waits) anyerror!?ai.failure.Failure {
        return work.models.finishSignIn(arena, work.pending.provider, work.pending.sign_in, work.redirect);
    }

    /// Answers which provider the person signed in to; one that refused the sign-in is told in its words.
    pub fn answer(work: *FinishSignIn, arena: Allocator, connection: *Connection, id: []const u8, outcome: anyerror!?ai.failure.Failure) void {
        const refused = outcome catch |err| return connection.refuseFailed(arena, id, err);
        if (refused) |failure| return connection.refuse(arena, id, "sign-in-failed", failure.message);
        connection.answer(arena, id, .{ .provider = work.pending.provider }) catch |err| connection.refuseFailed(arena, id, err);
    }

    pub fn deinit(work: *FinishSignIn) void {
        work.pending.arena_allocator.deinit();
    }
};
