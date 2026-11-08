//! Access to the host: who a client is, as the host's transport authenticated it — the session it holds, and the scopes
//! that session grants, each opening some of the protocol's methods — and the host's sessions and the links that pair
//! new clients, which the protocol's `access` methods read and change. The host keeps them, as it keeps the providers'
//! credentials, and Siphon reaches them through this; it never holds a secret, save a link's as it is made, handed
//! once to whoever made it.
const Access = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

context: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    /// The sessions and the links that pair, as they stand, none of their secrets.
    list: *const fn (context: *anyopaque, arena: Allocator) anyerror!Listed,
    /// A link made that pairs one client while it lasts, granting `scopes`: its secret, handed once.
    pair: *const fn (context: *anyopaque, arena: Allocator, label: ?[]const u8, scopes: []const Scope) anyerror!Paired,
    /// The session or the link of `id` revoked: which it was, or none where neither has that id.
    revoke: *const fn (context: *anyopaque, arena: Allocator, id: []const u8) anyerror!Revoked,
};

pub fn list(access: Access, arena: Allocator) !Listed {
    return access.vtable.list(access.context, arena);
}

pub fn pair(access: Access, arena: Allocator, label: ?[]const u8, scopes: []const Scope) !Paired {
    return access.vtable.pair(access.context, arena, label, scopes);
}

pub fn revoke(access: Access, arena: Allocator, id: []const u8) !Revoked {
    return access.vtable.revoke(access.context, arena, id);
}

/// What a session lets its client do: each scope opens some of the protocol's methods.
pub const Scope = enum {
    /// The threads, their logs and states, the models and which providers hold a credential.
    @"threads.read",
    /// Threads made, configured, delivered to, stopped and answered.
    @"threads.operate",
    /// The files of the machine the host runs on: its folders listed, its files read and searched.
    @"files.read",
    /// The terminals of the threads: opened on the machine, followed, typed into, sized and closed.
    @"terminals.operate",
    /// The browser's pages of the threads: opened, navigated, followed, clicked and typed into, and closed.
    @"browser.operate",
    /// The providers' credentials set and removed.
    @"providers.manage",
    /// The sessions and the links that pair, read.
    @"access.read",
    /// Links made, and sessions and links revoked.
    @"access.write",
};

/// Every scope: what a session gets where nothing narrower was asked for it.
pub const all_scopes: []const Scope = std.enums.values(Scope);

/// Who a connection's client is: the session it holds, by its id, and the scopes that session grants.
pub const Principal = struct {
    session: []const u8,
    scopes: []const Scope,

    /// Whether the session grants `scope`.
    pub fn allows(principal: Principal, scope: Scope) bool {
        return std.mem.indexOfScalar(Scope, principal.scopes, scope) != null;
    }
};

/// How a session's client holds it: a browser's cookie, a token a program sends, or the key a device's tunnel session
/// shows, as an SSH server knows a client by its authorized key.
pub const Method = enum { cookie, bearer, key };

/// A session, as the access methods show it: its id, how its client holds it, its scopes, its client's label, and when
/// it was issued and when it expires, in ms since the epoch.
pub const Session = struct {
    id: []const u8,
    method: Method,
    scopes: []const Scope,
    label: ?[]const u8 = null,
    issued_at: i64,
    expires_at: i64,
};

/// A link that pairs one client while it lasts, shown without its secret.
pub const Link = struct {
    id: []const u8,
    scopes: []const Scope,
    label: ?[]const u8 = null,
    created_at: i64,
    expires_at: i64,
};

/// The sessions and the links that pair.
pub const Listed = struct { sessions: []const Session, links: []const Link };

/// A link made: its id, the secret that pairs with it once, and when it expires.
pub const Paired = struct { id: []const u8, credential: []const u8, expires_at: i64 };

/// What a revocation took away: a session, a link, or nothing of that id.
pub const Revoked = enum { session, link, none };
