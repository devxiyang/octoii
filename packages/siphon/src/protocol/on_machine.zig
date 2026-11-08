//! An act on the machine the host runs on, as a client asks for one — a folder listed, a file read, a repository's
//! changes told: a method whose work is done off the loop as a job of the client's, on the machine opened for it, its
//! paths whole — from the machine's root, or from `~`, the home folder — the programs it runs sleeping on its task's
//! waits, which a stop wakes.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Machine = @import("../machine.zig");
const Waits = @import("../runtime.zig").Waits;
const Connection = @import("Connection.zig");
const Clients = @import("Clients.zig");

/// What an act reaches: the machine, opened for it; the host's io; and what its task sleeps on for the programs it runs.
pub const On = struct { machine: Machine, io: std.Io, waits: *Waits };

/// The method that does `act` off the loop: refused before it runs where the host gives no machine, or where the path
/// it is given is not whole.
pub fn method(comptime act: anytype) fn (*Connection, Allocator, []const u8, GivenOf(act)) anyerror!void {
    return struct {
        fn asked(connection: *Connection, _: Allocator, id: []const u8, given: GivenOf(act)) anyerror!void {
            if (connection.clients.machine.handle == null) return error.NoMachine;
            if (!isWhole(given.path)) return error.NotWhole;
            return connection.answerFromJob(id, Work(act), given);
        }
    }.asked;
}

/// What `act` is given: its last parameter.
fn GivenOf(comptime act: anytype) type {
    return @typeInfo(@TypeOf(act)).@"fn".param_types[2].?;
}

/// What `act` answers with, where it does not fail.
fn AnswerOf(comptime act: anytype) type {
    return @typeInfo(@typeInfo(@TypeOf(act)).@"fn".return_type.?).error_union.payload;
}

/// The work of `act`: what it was given, the machine it is done on, and the host's io.
fn Work(comptime act: anytype) type {
    return struct {
        pub const Given = GivenOf(act);

        host: Machine.Host,
        io: std.Io,
        given: Given,

        pub fn of(_: Allocator, clients: *Clients, given: Given) !@This() {
            return .{ .host = clients.machine, .io = clients.runtime.host.io, .given = given };
        }

        pub fn run(work: *@This(), arena: Allocator, waits: *Waits) anyerror!AnswerOf(act) {
            const machine = try Machine.open(work.host, .{ .base = .{ .workspace = Machine.root, .home = work.host.home } });
            defer machine.close();
            return act(arena, .{ .machine = machine, .io = work.io, .waits = waits }, work.given);
        }
    };
}

fn isWhole(path: []const u8) bool {
    return std.fs.path.isAbsolute(path) or std.mem.eql(u8, path, "~") or std.mem.startsWith(u8, path, "~/");
}
