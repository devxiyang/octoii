//! The MCP servers as a client is shown them, and the person's trust in a project's: the servers a thread working in a
//! folder would use, each as it stands, nothing started for the showing — read off the loop, as the machine is read —
//! and a decision on a project's configuration, made unasked or made again, recorded as an answer to its asking is.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Machine = @import("../machine.zig");
const runtime_ = @import("../runtime.zig");
const Changes = runtime_.Changes;
const Waits = runtime_.Waits;
const tools = @import("../tools.zig");
const Servers = tools.Servers;
const trust = tools.trust;
const Connection = @import("Connection.zig");
const Clients = @import("Clients.zig");

/// The servers a thread working in `workspace` would use — the person's alone, where it names none — as `Listed` shows
/// them.
pub fn list(connection: *Connection, _: Allocator, id: []const u8, given: Listing.Given) !void {
    return connection.answerFromJob(id, Listing, given);
}

/// The work of listing: the servers, the machine whose folder the project is found from, and the folder.
const Listing = struct {
    pub const Given = struct { workspace: ?[]const u8 = null };

    servers: *Servers,
    host: Machine.Host,
    given: Given,

    pub fn of(_: Allocator, clients: *Clients, given: Given) !Listing {
        return .{ .servers = clients.servers, .host = clients.machine, .given = given };
    }

    pub fn run(listing: *Listing, arena: Allocator, _: *Waits) !Servers.Listed {
        const workspace = listing.given.workspace;
        return listing.servers.list(arena, .{ .workspace = workspace, .project = try Machine.projectAt(listing.host, arena, workspace) });
    }
};

/// What the person decided on the configuration of a project's folder of a digest, recorded in place of what they
/// decided on it before: a fiber asking it ends, and the threads of the project run its servers, or no longer do, as
/// they next gather what their models are told.
pub fn decide(connection: *Connection, arena: Allocator, id: []const u8, given: trust.Decision) !void {
    const runtime = connection.clients.runtime;
    var changes: Changes = .{ .arena = arena };
    try trust.record(&changes, arena, given);
    _ = try runtime.commit(&changes);
    return connection.answer(arena, id, Connection.nothing);
}
