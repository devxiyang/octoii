//! A client's connection, as Siphon speaks to it: messages of JSON, carried by the host on its transport. The client
//! sends messages as JSON-RPC's are: each its id, the method it asks and the method's parameters, `params`, which the
//! method reads as its own, strictly, as a system call takes its arguments; each is answered once by its id. The host's
//! transport authenticated the client as it connected, by the session it holds; its first message is `hello`, which
//! names the protocol's version, answered with that session and its scopes, and each method asks a scope of them, as a
//! system call is checked against what its caller may do. It follows threads and watches the list of them, as
//! `Following` feeds it; it answers the requests a thread's fibers make of the person, as the thread's state shows them
//! waiting; it sets the providers' credentials the host keeps, told which provider holds what kind of one — never the
//! credential itself; it is told the models a thread may run with, and the MCP servers a thread working in a folder
//! would use, and records what the person decides on a project's; it reads the machine's files — a folder's names, a
//! file's page, the paths under a folder that match what is asked for; it opens a thread's terminals, follows them in
//! views of its own size, types into them and closes them; and it reads the host's sessions and the links that pair new
//! clients, makes links and revokes them. An answer leaves once what its method changed of what the client follows was
//! fed, so the client holds the change as the answer comes, the commits it tells of durable as they returned. A method
//! that fails is refused by one table of the protocol's failures, each a code and its words.
//!
//! Siphon's loop alone touches a connection; the host's tasks reach it through two queues: what the client sends is
//! delivered to the loop as work posted to it, and what it is sent the host takes from the connection's outbox. What the
//! client follows is fed while the outbox has room, so a client that reads slowly is fed slowly; one whose outbox grows
//! all the same, with answers and what streams, is let go as Redis lets go of a client whose output buffer grows past
//! its limits — at once past the hard one, after a while past the soft one — and reads on from where it stood when it
//! comes again.
const Connection = @This();

const std = @import("std");
const ai = @import("ai");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const Runtime = runtime_.Runtime;
const Waits = runtime_.Waits;
const threads = @import("../threads.zig");
const log = threads.log;
const settings = @import("../settings.zig");
const runtime_ = @import("../runtime.zig");
const Changes = runtime_.Changes;
const beak = @import("../beak.zig");
const Machine = @import("../machine.zig");
const tools = @import("../tools.zig");
const agent = @import("../agent.zig");
const Tool = tools.Tool;
const permissions = tools.permissions;
const Clients = @import("Clients.zig");
const Following = @import("Following.zig");
const Access = @import("Access.zig");
const Providers = @import("Providers.zig");
const files = @import("files.zig");
const terminals = @import("terminals.zig");
const git = @import("git.zig");
const pages = @import("pages.zig");
const servers = @import("servers.zig");

/// The protocol's version, which `hello` names.
pub const protocol = 1;

/// How many messages wait in an outbox at most before its client is let go.
const outbox_max = 4096;
/// How many bytes may wait in an outbox: past the hard bound its client is let go at once; past the soft one for longer
/// than `outbox_soft_ms`, then.
pub const outbox_hard_bytes = 32 << 20;
pub const outbox_soft_bytes = 8 << 20;
pub const outbox_soft_ms = 60 * std.time.ms_per_s;
/// How many bytes may wait in an outbox for what the client follows to be fed more: the room a feed waits for.
pub const feed_room_bytes = 1 << 20;

clients: *Clients,
allocator: Allocator,
/// Who the host's transport authenticated the client to be, arena as the connection's own; none, it holds no session.
principal: ?Access.Principal,
/// Set once `hello` was answered: the client may ask the methods its session's scopes open.
greeted: bool = false,
/// What the client follows: threads, and the list of them.
following: Following,
/// What the client is to be sent, in order, each message the taker's to free with `allocator`.
outbox: std.Io.Queue([]u8),
outbox_buffer: [][]u8,
/// How many bytes wait in the outbox: the loop adds what it puts there, the host's taker takes away what it takes.
queued: std.atomic.Value(usize) = .init(0),
/// Set while a feed waits for room in the outbox: the taker that makes room wakes the loop.
wants_room: std.atomic.Value(bool) = .init(false),
/// Since when the outbox has stood past its soft bound, as the loop saw it; null while it stands within it.
soft_since: ?i64 = null,
/// Set once the outbox is closed: the client is gone, or let go.
closed: bool = false,
/// Who holds the connection: Siphon's loop, from its opening till it takes the client's hang-up, and the host, till its
/// taker of the outbox is done. The last to let go frees it.
holders: std.atomic.Value(u32) = .init(2),
/// How many jobs of the client's methods run now, each holding the connection till it ends. The loop alone changes it.
jobs: u8 = 0,

/// A message a client sends: its id, the method it asks, and the method's parameters, which the method reads as its
/// own; none, where it takes none.
const Envelope = struct { id: []const u8, method: []const u8, params: ?foundation.json.Raw = null };

/// How a message and its parameters are read: strictly — a field the reader does not take refuses the message, so one
/// meant for another method is never taken in silence.
const strict: std.json.ParseOptions = .{ .ignore_unknown_fields = false, .allocate = .alloc_always };

/// The result of a method that gives back nothing.
pub const nothing: struct {} = .{};

/// A connection of `clients`', for the client `principal` names, as `Clients.open` makes one for the host.
pub fn create(clients: *Clients, principal: ?Access.Principal) Allocator.Error!*Connection {
    const allocator = clients.runtime.allocator;
    const connection = try allocator.create(Connection);
    errdefer allocator.destroy(connection);
    const buffer = try allocator.alloc([]u8, outbox_max);
    errdefer allocator.free(buffer);
    const arena = if (principal) |given| try ownPrincipal(allocator, given) else null;
    connection.* = .{ .clients = clients, .allocator = allocator, .principal = arena, .following = .{ .allocator = allocator }, .outbox = .init(buffer), .outbox_buffer = buffer };
    return connection;
}

/// A copy of `principal` the connection holds.
fn ownPrincipal(allocator: Allocator, principal: Access.Principal) Allocator.Error!Access.Principal {
    const session = try allocator.dupe(u8, principal.session);
    errdefer allocator.free(session);
    return .{ .session = session, .scopes = try allocator.dupe(Access.Scope, principal.scopes) };
}

/// Whether the client holds the session `session`.
pub fn holds(connection: *const Connection, session: []const u8) bool {
    const principal = connection.principal orelse return false;
    return std.mem.eql(u8, principal.session, session);
}

/// Gives the loop a message the client sent, copied, from any task: the loop takes it as it pumps, the connection's
/// answer, or why it was refused, put in the outbox.
pub fn deliver(connection: *Connection, message: []const u8) Allocator.Error!void {
    const delivered = try connection.allocator.create(Delivered);
    errdefer connection.allocator.destroy(delivered);
    delivered.* = .{ .allocator = connection.allocator, .connection = connection, .message = try connection.allocator.dupe(u8, message) };
    connection.clients.runtime.post(.{ .context = delivered, .run = Delivered.run, .drop = Delivered.drop });
}

/// A message a client sent, as the loop takes it. It keeps its own allocator: one dropped as the runtime closes may
/// outlive its connection.
const Delivered = struct {
    allocator: Allocator,
    connection: *Connection,
    message: []u8,

    fn run(context: *anyopaque) void {
        const delivered: *Delivered = @ptrCast(@alignCast(context));
        defer drop(context);
        delivered.connection.receive(delivered.message);
    }

    fn drop(context: *anyopaque) void {
        const delivered: *Delivered = @ptrCast(@alignCast(context));
        const allocator = delivered.allocator;
        allocator.free(delivered.message);
        allocator.destroy(delivered);
    }
};

/// Tells the loop the client is gone, from any task: the loop lets go of the connection, its outbox closed, so the
/// host's taker ends with what was left; then the host lets go too.
pub fn hangUp(connection: *Connection) void {
    connection.clients.runtime.post(.{ .context = connection, .run = gone, .drop = goneUnheard });
}

fn gone(context: *anyopaque) void {
    const connection: *Connection = @ptrCast(@alignCast(context));
    connection.clients.leave(connection);
}

/// The runtime closes before it takes the hang-up: the clients let go of the connection as they close.
fn goneUnheard(_: *anyopaque) void {}

/// How many jobs a client's methods may run at once: one that would run another is refused as busy.
const jobs_max = 8;

/// A method's work that goes off the loop — the network, a provider's server, the machine's files — as a job of the
/// runtime's, as Redis blocks a client while a module works on another thread and replies to it on its own. The job
/// holds its own copy of what the method was given, and the connection, till it ends. `Work.of` makes the work of them,
/// on the loop; `Work.run` does it in the job's task, sleeping on the task's waits for what it starts; and what it
/// gives — an answer, or a failure — the client is answered with back on the loop, a failure told as every method's
/// is. `Work.answer`, where the work has one, answers instead, for a work whose end changes what the loop holds;
/// `Work.deinit`, where it has one, lets go of what it holds.
pub fn answerFromJob(connection: *Connection, id: []const u8, comptime Work: type, given: Work.Given) !void {
    if (connection.jobs >= jobs_max) return error.Busy;
    const job = try Job(Work).make(connection, id, given);
    errdefer job.free();
    try connection.clients.runtime.spawn(.{ .context = job, .run = Job(Work).run, .finish = Job(Work).finish, .drop = Job(Work).drop });
}

fn Job(comptime Work: type) type {
    return struct {
        const Self = @This();
        /// What the work gives as it is done: its answer, or its failure.
        const Outcome = @typeInfo(@TypeOf(Work.run)).@"fn".return_type.?;

        arena_allocator: std.heap.ArenaAllocator,
        connection: *Connection,
        id: []const u8,
        work: Work,
        /// What the work gave, set as it is done, before the job finishes.
        outcome: Outcome = undefined,

        /// The job, holding the connection and counted among its jobs till it is freed.
        fn make(connection: *Connection, id: []const u8, given: Work.Given) !*Self {
            var arena_allocator: std.heap.ArenaAllocator = .init(connection.allocator);
            errdefer arena_allocator.deinit();
            const arena = arena_allocator.allocator();
            const job = try arena.create(Self);
            job.* = .{ .arena_allocator = undefined, .connection = connection, .id = try arena.dupe(u8, id), .work = try Work.of(arena, connection.clients, try owned(arena, given)) };
            job.arena_allocator = arena_allocator;
            connection.jobs += 1;
            _ = connection.holders.fetchAdd(1, .acq_rel);
            return job;
        }

        fn run(context: *anyopaque, waits: *Waits) void {
            const job: *Self = @ptrCast(@alignCast(context));
            job.outcome = job.work.run(job.arena_allocator.allocator(), waits);
        }

        fn finish(context: *anyopaque) void {
            const job: *Self = @ptrCast(@alignCast(context));
            const arena = job.arena_allocator.allocator();
            if (@hasDecl(Work, "answer")) {
                job.work.answer(arena, job.connection, job.id, job.outcome);
            } else job.connection.answerWith(arena, job.id, job.outcome);
            job.free();
        }

        /// Lets go of the job unfinished, as the runtime closes: its client is answered no more.
        fn drop(context: *anyopaque) void {
            const job: *Self = @ptrCast(@alignCast(context));
            job.free();
        }

        fn free(job: *Self) void {
            if (@hasDecl(Work, "deinit")) job.work.deinit();
            const connection = job.connection;
            connection.jobs -= 1;
            var arena_allocator = job.arena_allocator;
            arena_allocator.deinit();
            connection.release();
        }
    };
}

/// Answers the message `id` with what a method came to: its answer — nothing, where it gives none — or its failure,
/// told as every method's is.
fn answerWith(connection: *Connection, arena: Allocator, id: []const u8, outcome: anytype) void {
    const result = outcome catch |err| return connection.refuseFailed(arena, id, err);
    connection.answer(arena, id, if (@TypeOf(result) == void) nothing else result) catch |err| connection.refuseFailed(arena, id, err);
}

/// `value` with every slice it holds copied into `arena`, so it outlives the message it was read from.
fn owned(arena: Allocator, value: anytype) Allocator.Error!@TypeOf(value) {
    switch (@typeInfo(@TypeOf(value))) {
        .pointer => |pointer| {
            comptime std.debug.assert(pointer.size == .slice);
            const copy = try arena.dupe(pointer.child, value);
            for (copy) |*each| each.* = try owned(arena, each.*);
            return copy;
        },
        .optional => return if (value) |inner| try owned(arena, inner) else null,
        .@"struct" => |fields| {
            var copy = value;
            inline for (fields.field_names) |name| @field(copy, name) = try owned(arena, @field(value, name));
            return copy;
        },
        .@"union" => switch (value) {
            inline else => |payload, tag| return @unionInit(@TypeOf(value), @tagName(tag), try owned(arena, payload)),
        },
        else => return value,
    }
}

/// Lets go of the connection, for Siphon's loop or for the host: the last to let go frees it.
pub fn release(connection: *Connection) void {
    if (connection.holders.fetchSub(1, .acq_rel) == 1) connection.destroy();
}

/// Frees the connection and what its outbox still holds.
fn destroy(connection: *Connection) void {
    const allocator = connection.allocator;
    var left: [64][]u8 = undefined;
    while (true) {
        const count = connection.outbox.get(connection.clients.runtime.host.io, &left, 0) catch break;
        if (count == 0) break;
        for (left[0..count]) |message| allocator.free(message);
    }
    connection.following.deinit();
    if (connection.principal) |principal| {
        allocator.free(principal.session);
        allocator.free(principal.scopes);
    }
    allocator.free(connection.outbox_buffer);
    allocator.destroy(connection);
}

/// Closes the outbox: the host's taker gets what is left, then sees it closed.
pub fn close(connection: *Connection) void {
    if (connection.closed) return;
    connection.closed = true;
    connection.outbox.close(connection.clients.runtime.host.io);
}

/// Takes what the client is to be sent into `batch`, in order, at least `min` messages, waiting for them, as a read of a
/// pipe does: the host's taker's to send, each freed with the connection's allocator; `error.Closed` once the outbox is
/// closed and empty. What it takes makes room in the outbox, and a feed waiting for room goes on.
pub fn take(connection: *Connection, batch: [][]u8, min: usize) (std.Io.QueueClosedError || std.Io.Cancelable)!usize {
    const count = try connection.outbox.get(connection.clients.runtime.host.io, batch, min);
    var bytes: usize = 0;
    for (batch[0..count]) |message| bytes += message.len;
    const left = connection.queued.fetchSub(bytes, .seq_cst) - bytes;
    if (left < feed_room_bytes and connection.wants_room.swap(false, .seq_cst)) connection.clients.runtime.wake();
    return count;
}

/// Takes one message the client sent: its answer, or why it was refused, put in the outbox.
pub fn receive(connection: *Connection, message: []const u8) void {
    var arena_allocator: std.heap.ArenaAllocator = .init(connection.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const given = std.json.parseFromSliceLeaky(Envelope, arena, message, strict) catch return connection.refuseMalformed(arena, message);
    connection.respond(arena, given) catch |err| return connection.refuseFailed(arena, given.id, err);
}

/// Why a method was refused, as its client is told: a code, and words — as errno names a failure and strerror says it.
const Refusal = struct { code: []const u8, told: []const u8 };

/// The refusal of a method that failed with `err`: in words where the failure is one the protocol names, else by its
/// name.
fn refusalOf(err: anyerror) Refusal {
    return switch (err) {
        error.NotGreeted => .{ .code = "not-admitted", .told = "Say hello first." },
        error.NoSession => .{ .code = "not-admitted", .told = "This client holds no session of the host's: pair it first." },
        error.OtherProtocol => .{ .code = "protocol", .told = "Siphon speaks the protocol's version 1." },
        error.UnknownMethod => .{ .code = "unknown-method", .told = "No method has that name." },
        error.Busy => .{ .code = "busy", .told = "The client's methods that run off the loop already run as many as it may: ask again once one is answered." },
        // The threads.
        error.NoSuchThread => .{ .code = "no-such-thread", .told = "No thread has that id." },
        error.NoSuchRequest => .{ .code = "no-such-request", .told = "No request of that key waits in the thread." },
        error.NoSuchEntry => .{ .code = "no-such-entry", .told = "The thread's log holds no entry of that id." },
        error.NotAskedOfPerson => .{ .code = "not-asked-of-person", .told = "The request is not one a person answers." },
        error.InvalidOperation => .{ .code = "invalid", .told = "An operation's id is a name: neither empty, nor holding a slash or a NUL." },
        error.InvalidCursor => .{ .code = "invalid", .told = "The cursor stands nowhere in the thread's log." },
        error.OperationReused => .{ .code = "operation-reused", .told = "The operation's id was given before, to another method or another thread." },
        // The settings.
        error.EnvironmentNotOperated => .{ .code = "forbidden", .told = "The environment's settings are changed by a session that operates the threads." },
        error.NothingChanged => .{ .code = "invalid", .told = "Nothing to set." },
        error.NotAnObject => .{ .code = "invalid", .told = "A device's settings are an object of names." },
        error.SettingsTooLarge => .{ .code = "too-large", .told = "A device's settings hold at most 64 KiB." },
        // The providers and their credentials.
        error.UnknownProvider => .{ .code = "unknown-provider", .told = "No provider has that id." },
        error.NoCredentials => .{ .code = "unavailable", .told = "The host keeps no credentials." },
        error.CredentialNotKept => .{ .code = "unavailable", .told = "The host could not keep the credential." },
        error.CredentialNotForgotten => .{ .code = "unavailable", .told = "The host could not forget the credential." },
        error.NotSignedInTo => .{ .code = "invalid", .told = "The provider is not signed in to: it takes a key, or none." },
        error.NoSignInReturn => .{ .code = "unavailable", .told = "The host takes no sign-in back." },
        error.NoSignIn => .{ .code = "no-sign-in", .told = "No sign-in waits for its end: begin one." },
        // The host's access.
        error.NoAccess => .{ .code = "unavailable", .told = "The host keeps no access." },
        error.WiderThanSession => .{ .code = "forbidden", .told = "A link grants no more than the session that makes it." },
        error.NoSuchAccess => .{ .code = "no-such-access", .told = "No session or link has that id." },
        // The machine's files and terminals.
        error.NoMachine => .{ .code = "unavailable", .told = "The host gives no machine." },
        error.NoShell => .{ .code = "unavailable", .told = "The host names no shell for a terminal." },
        error.NoSuchTerminal => .{ .code = "no-such-terminal", .told = "No terminal has that id." },
        error.NotFollowed => .{ .code = "not-followed", .told = "The client follows no terminal of that id." },
        error.EmptyView => .{ .code = "invalid", .told = "A view holds a row and a column at least: of cells, or of pixels." },
        error.NoBrowser => .{ .code = "unavailable", .told = "The host names no browser: install Chrome, Chromium or Edge on its machine." },
        error.NoSuchPage => .{ .code = "no-such-page", .told = "No page has that id." },
        error.NotWhole => .{ .code = "invalid", .told = "A path on the machine is whole: from its root, or from ~, the home folder." },
        error.NotFound => .{ .code = "not-found", .told = "Nothing is at that path." },
        error.NotADirectory => .{ .code = "not-a-directory", .told = "That path names no folder." },
        error.IsADirectory => .{ .code = "is-a-directory", .told = "That path names a folder." },
        error.TooLarge => .{ .code = "too-large", .told = "The file is larger than a read gives." },
        error.Refused => .{ .code = "refused", .told = "The machine refused the access." },
        error.Invalid => .{ .code = "invalid", .told = "The machine takes no such path or range." },
        error.MissingProgram => .{ .code = "unavailable", .told = "The machine has no such program: git, where a repository was asked of." },
        error.TimedOut => .{ .code = "timed-out", .told = "The program ran past its time, and was ended." },
        error.OutputTooLarge => .{ .code = "too-large", .told = "The program wrote more than is taken." },
        // The repositories.
        error.NotARepository => .{ .code = "not-a-repository", .told = "That folder is in no repository of git's." },
        error.NoBase => .{ .code = "no-base", .told = "The repository has no branch its work was taken from: name one." },
        error.InvalidRevision => .{ .code = "invalid", .told = "A tree is named by its object's id, and a branch by its name." },
        error.GitFailed => .{ .code = "failed", .told = "Git refused what it was asked; the host's log tells why." },
        else => .{ .code = "failed", .told = @errorName(err) },
    };
}

/// Refuses the message `id` for the failure `err`, as every method's failure is told.
pub fn refuseFailed(connection: *Connection, arena: Allocator, id: ?[]const u8, err: anyerror) void {
    const refusal = refusalOf(err);
    connection.refuse(arena, id, refusal.code, refusal.told);
}

/// Tells the connection a commit touched the thread `tid`: what the client follows of it is fed as the pump ends.
pub fn changed(connection: *Connection, tid: []const u8) void {
    connection.following.changed(tid);
}

/// Tells the connection every thread may have changed.
pub fn changedAll(connection: *Connection) void {
    connection.following.changedAll();
}

/// Feeds the client what changed of what it follows while its outbox has room, and lets go of one whose outbox stood
/// past its soft bound too long; whether a page is left to feed while it has room.
pub fn feed(connection: *Connection) bool {
    if (connection.pastSoftBound()) {
        connection.close();
        return false;
    }
    return connection.following.feed(connection);
}

/// Whether the outbox has stood past its soft bound longer than its client may keep it so.
fn pastSoftBound(connection: *Connection) bool {
    if (connection.queued.load(.seq_cst) <= outbox_soft_bytes) {
        connection.soft_since = null;
        return false;
    }
    const now = connection.clients.runtime.now();
    const since = connection.soft_since orelse {
        connection.soft_since = now;
        return false;
    };
    return now - since > outbox_soft_ms;
}

/// Whether the outbox has room for a feed; where it has none, the host's taker is asked to wake the loop as it makes
/// some.
pub fn hasRoom(connection: *Connection) bool {
    if (connection.closed) return false;
    if (connection.queued.load(.seq_cst) < feed_room_bytes) return true;
    connection.wants_room.store(true, .seq_cst);
    // A taker that made room since is seen here; one that makes it after sees the flag.
    if (connection.queued.load(.seq_cst) >= feed_room_bytes) return false;
    connection.wants_room.store(false, .seq_cst);
    return true;
}

/// Sends the client `event`, a JSON object of what streams of the thread `tid` for its request `key`, by its offset in the
/// stream, where it follows the thread and was sent what streamed of it before.
pub fn offer(connection: *Connection, tid: []const u8, key: []const u8, offset: u64, event: []const u8) void {
    if (!connection.following.streamsSent(tid)) return;
    var arena_allocator: std.heap.ArenaAllocator = .init(connection.allocator);
    defer arena_allocator.deinit();
    connection.send(Following.streamEvent(arena_allocator.allocator(), tid, key, offset, event) catch return);
}

fn respond(connection: *Connection, arena: Allocator, given: Envelope) !void {
    const params = if (given.params) |raw| raw.text else "{}";
    if (std.mem.eql(u8, given.method, greeting.name)) return greeting.run(connection, arena, given.id, params);
    if (!connection.greeted) return error.NotGreeted;
    for (methods) |each| if (std.mem.eql(u8, each.name, given.method)) {
        const scope = each.scope.?;
        if (!connection.principal.?.allows(scope)) {
            const told = try arena.print("The session grants no {s}, which {s} asks.", .{ @tagName(scope), each.name });
            return connection.refuse(arena, given.id, "forbidden", told);
        }
        return each.run(connection, arena, given.id, params);
    };
    return error.UnknownMethod;
}

/// A method of the protocol: its name, the scope a session must grant for its client to ask it — none for `hello`, which
/// every client may — and what answers a message that asks it, or refuses it, through the connection, given the
/// message's id and its parameters as they came.
const Method = struct {
    name: []const u8,
    scope: ?Access.Scope,
    run: *const fn (connection: *Connection, arena: Allocator, id: []const u8, params: []const u8) anyerror!void,
};

/// The method `name`, open to a session that grants `scope`, answered by `act`, whose last parameter is the method's
/// parameters, read as its type, strictly: a field it does not take, one it needs and is not given, or one of another
/// shape refuses the message as invalid.
fn method(comptime name: []const u8, comptime scope: ?Access.Scope, comptime act: anytype) Method {
    const Params = @typeInfo(@TypeOf(act)).@"fn".param_types[3].?;
    const read = struct {
        fn run(connection: *Connection, arena: Allocator, id: []const u8, params: []const u8) anyerror!void {
            const given = std.json.parseFromSliceLeaky(Params, arena, params, strict) catch |err| return connection.refuse(arena, id, "invalid", paramsTold(err));
            return act(connection, arena, id, given);
        }
    };
    return .{ .name = name, .scope = scope, .run = read.run };
}

/// What a client is told of parameters its method could not read.
fn paramsTold(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownField => "The params hold a field the method does not take.",
        error.MissingField => "The params lack a field the method needs.",
        else => "The params are not of the method's shape.",
    };
}

/// `hello`, the one method a client may ask before it is answered.
const greeting = method("hello", null, hello);

/// The protocol's methods, as Redis's command table holds its commands: each by its name, the scope it asks and its
/// parameters, open to a client once `hello` was answered and its session grants the scope.
const methods = [_]Method{
    method("threads.list", .@"threads.read", threadsList),
    method("threads.create", .@"threads.operate", threadsCreate),
    method("threads.configure", .@"threads.operate", threadsConfigure),
    method("threads.delete", .@"threads.operate", threadsDelete),
    method("threads.deliver", .@"threads.operate", threadsDeliver),
    method("threads.withdraw", .@"threads.operate", threadsWithdraw),
    method("threads.stop", .@"threads.operate", threadsStop),
    method("threads.state", .@"threads.read", threadsState),
    method("threads.answer", .@"threads.operate", threadsAnswer),
    method("threads.context", .@"threads.read", threadsContext),
    method("threads.compact", .@"threads.operate", threadsCompact),
    method("threads.read", .@"threads.read", threadsRead),
    method("threads.follow", .@"threads.read", threadsFollow),
    method("threads.unfollow", .@"threads.read", threadsUnfollow),
    method("threads.watch", .@"threads.read", threadsWatch),
    method("threads.unwatch", .@"threads.read", threadsUnwatch),
    method("settings.watch", .@"threads.read", settingsWatch),
    method("settings.unwatch", .@"threads.read", settingsUnwatch),
    method("settings.set", .@"threads.read", settingsSet),
    method("grants.list", .@"threads.read", grantsList),
    method("servers.list", .@"threads.read", servers.list),
    method("trust.decide", .@"threads.operate", servers.decide),
    method("grants.revoke", .@"threads.operate", grantsRevoke),
    method("providers.list", .@"threads.read", Providers.list),
    method("providers.status", .@"threads.read", Providers.status),
    method("providers.sign-in", .@"providers.manage", Providers.signIn),
    method("providers.finish-sign-in", .@"providers.manage", Providers.finishSignIn),
    method("credentials.set", .@"providers.manage", credentialsSet),
    method("credentials.remove", .@"providers.manage", credentialsRemove),
    method("models.list", .@"threads.read", modelsList),
    method("models.refresh", .@"threads.read", Providers.refresh),
    method("files.list", .@"files.read", files.list),
    method("files.read", .@"files.read", files.read),
    method("files.search", .@"files.read", files.search),
    method("git.repository", .@"files.read", git.repository),
    method("git.changes", .@"files.read", git.changes),
    method("git.patch", .@"files.read", git.patch),
    method("git.versions", .@"files.read", git.versions),
    method("git.commits", .@"files.read", git.commits),
    method("terminals.open", .@"terminals.operate", terminals.open),
    method("terminals.follow", .@"terminals.operate", terminals.follow),
    method("terminals.unfollow", .@"terminals.operate", terminals.unfollow),
    method("terminals.write", .@"terminals.operate", terminals.write),
    method("terminals.resize", .@"terminals.operate", terminals.resize),
    method("terminals.close", .@"terminals.operate", terminals.close),
    method("browser.open", .@"browser.operate", pages.open),
    method("browser.navigate", .@"browser.operate", pages.navigate),
    method("browser.back", .@"browser.operate", pages.back),
    method("browser.forward", .@"browser.operate", pages.forward),
    method("browser.reload", .@"browser.operate", pages.reload),
    method("browser.dialog", .@"browser.operate", pages.dialog),
    method("browser.close", .@"browser.operate", pages.close),
    method("browser.follow", .@"browser.operate", pages.follow),
    method("browser.resize", .@"browser.operate", pages.resize),
    method("browser.unfollow", .@"browser.operate", pages.unfollow),
    method("browser.mouse", .@"browser.operate", pages.mouse),
    method("browser.key", .@"browser.operate", pages.key),
    method("browser.text", .@"browser.operate", pages.text),
    method("access.list", .@"access.read", accessList),
    method("access.pair", .@"access.write", accessPair),
    method("access.revoke", .@"access.write", accessRevoke),
};

/// The threads, each with its manifest and its state.
fn threadsList(connection: *Connection, arena: Allocator, id: []const u8, _: struct {}) !void {
    return connection.answer(arena, id, .{ .threads = try threads.list(connection.clients.runtime, arena) });
}

/// A thread made of the manifest given, once for the operation's id: its id.
/// A manifest as a client makes a thread with: its mode the one the environment's settings name where it gives none;
/// its project the one its workspace is in, as the machine finds it.
const ManifestGiven = struct {
    model: ?[]const u8 = null,
    workspace: ?[]const u8 = null,
    title: ?[]const u8 = null,
    mode: ?threads.Mode = null,
    effort: ?threads.Effort = null,
};

fn threadsCreate(connection: *Connection, arena: Allocator, id: []const u8, given: struct { manifest: ManifestGiven = .{}, operation: []const u8 }) !void {
    const runtime = connection.clients.runtime;
    const manifest: threads.Manifest = .{
        // The default folder is where a thread that names none works, not a project it belongs to.
        .project = try Machine.projectAt(connection.clients.machine, arena, given.manifest.workspace),
        .model = given.manifest.model,
        .workspace = given.manifest.workspace orelse try Machine.defaultWorkspace(connection.clients.machine, arena),
        .title = given.manifest.title,
        .mode = given.manifest.mode orelse (try settings.environmentOf(runtime.volume, &arena)).thread_mode,
        .effort = given.manifest.effort,
    };
    const tid = try threads.create(runtime, arena, manifest, given.operation);
    return connection.answer(arena, id, .{ .thread = tid });
}

/// What the person granted every project, a project a list of grants.
fn grantsList(connection: *Connection, arena: Allocator, id: []const u8, _: struct {}) !void {
    return connection.answer(arena, id, .{ .grants = try permissions.every(connection.clients.runtime, arena) });
}

/// A grant taken back from the project at `folder`: the pattern `pattern` of the action `action`.
fn grantsRevoke(connection: *Connection, arena: Allocator, id: []const u8, given: struct { folder: []const u8, action: Tool.Action, pattern: []const u8 }) !void {
    const runtime = connection.clients.runtime;
    var changes: Changes = .{ .arena = arena };
    try permissions.revoke(&changes, runtime, arena, given.folder, given.action, given.pattern);
    _ = try runtime.commit(&changes);
    return connection.answer(arena, id, nothing);
}

/// A thread's manifest changed as the person changes it — its model, title, mode or effort; whether it is pinned or
/// archived, and till when it is snoozed and seen — each one given in place of the one it had.
fn threadsConfigure(connection: *Connection, arena: Allocator, id: []const u8, given: struct { thread: []const u8, changes: threads.Configured }) !void {
    try threads.configure(connection.clients.runtime, arena, given.thread, given.changes);
    return connection.answer(arena, id, nothing);
}

/// A thread deleted, whatever it was doing — its fibers killed, what they asked cut off — and what the clients kept of
/// it let go of: its terminals, its pages, and every client's following of it; and what the providers keep of its
/// conversation.
fn threadsDelete(connection: *Connection, arena: Allocator, id: []const u8, given: struct { thread: []const u8 }) !void {
    const deleted = try threads.delete(connection.clients.runtime, arena, given.thread);
    for (deleted) |tid| connection.clients.forgetThread(tid);
    connection.clients.forgetConversations(deleted);
    return connection.answer(arena, id, nothing);
}

/// An input delivered to a thread, once for the operation's id: the input's id.
fn threadsDeliver(connection: *Connection, arena: Allocator, id: []const u8, given: struct { thread: []const u8, input: threads.Input, operation: []const u8 }) !void {
    const delivered = try threads.deliver(connection.clients.runtime, arena, given.thread, given.input, given.operation);
    return connection.answer(arena, id, .{ .input = delivered });
}

/// An input taken back while it waits in a thread's inbox: whether it was still there.
fn threadsWithdraw(connection: *Connection, arena: Allocator, id: []const u8, given: struct { thread: []const u8, input_id: []const u8 }) !void {
    const withdrawn = try threads.withdraw(connection.clients.runtime, arena, given.thread, given.input_id);
    return connection.answer(arena, id, .{ .withdrawn = withdrawn });
}

/// What fills a thread's window: its tokens, and each part's share of them, near.
fn threadsContext(connection: *Connection, arena: Allocator, id: []const u8, given: struct { thread: []const u8 }) !void {
    const runtime = connection.clients.runtime;
    const thread = try threads.pathOf(arena, given.thread);
    if (try runtime.volume.stat(&arena, thread) == null) return error.NoSuchThread;
    return connection.answer(arena, id, try agent.context.of(runtime, &arena, thread));
}

/// A thread's window compacted as the person asks, in the background while a turn runs on: whether its compaction was
/// started — not where one runs already, as a thread compacts once at a time.
fn threadsCompact(connection: *Connection, arena: Allocator, id: []const u8, given: struct { thread: []const u8 }) !void {
    const runtime = connection.clients.runtime;
    const thread = try threads.pathOf(arena, given.thread);
    if (try runtime.volume.stat(&arena, thread) == null) return error.NoSuchThread;
    var changes: Changes = .{ .arena = arena };
    const started = try agent.compacting.start(&changes, runtime, &arena, thread);
    if (started) _ = try runtime.commit(&changes);
    return connection.answer(arena, id, .{ .started = started });
}

/// A thread stopped for the person: their waiting inputs withdrawn, its turn asked to stop.
fn threadsStop(connection: *Connection, arena: Allocator, id: []const u8, given: struct { thread: []const u8 }) !void {
    try threads.stop(connection.clients.runtime, arena, given.thread, "person");
    return connection.answer(arena, id, nothing);
}

/// What a thread is doing.
fn threadsState(connection: *Connection, arena: Allocator, id: []const u8, given: struct { thread: []const u8 }) !void {
    return connection.answer(arena, id, try threads.state(connection.clients.runtime, arena, given.thread));
}

/// The person's answer to a request of a thread's that a person answers, given where it fits what the request asks.
fn threadsAnswer(connection: *Connection, arena: Allocator, id: []const u8, given: struct { thread: []const u8, request: []const u8, answer: foundation.json.Raw }) !void {
    return switch (try threads.answer(connection.clients.runtime, arena, given.thread, given.request, given.answer)) {
        .given => connection.answer(arena, id, nothing),
        .unfit => |why| connection.refuse(arena, id, "invalid", why),
    };
}

/// How many entries a page of a thread's log read back holds at most.
const read_max = 1000;

/// A page of a thread's log read back: at most `limit` entries before the entry `before` — before the log's end, where
/// none is named — in the log's order; where the log ended as it was read, for a client that follows on from there; and
/// whether they reach the log's start — as a history is read back a page at a time, and its latest followed on.
fn threadsRead(connection: *Connection, arena: Allocator, id: []const u8, given: struct { thread: []const u8, before: ?[]const u8 = null, limit: u32 }) !void {
    const runtime = connection.clients.runtime;
    const thread = try threads.pathOf(arena, given.thread);
    if (try runtime.volume.stat(&arena, thread) == null) return error.NoSuchThread;
    const page = try log.readBefore(runtime.volume, &arena, thread, given.before, @min(given.limit, read_max));
    const entries = try arena.alloc(foundation.json.Raw, page.lines.len);
    for (page.lines, entries) |line, *entry| entry.* = .{ .text = line };
    return connection.answer(arena, id, .{ .entries = entries, .end = page.end, .complete = page.complete });
}

/// A thread followed, from where the client's reader stood or from its start.
fn threadsFollow(connection: *Connection, arena: Allocator, id: []const u8, given: struct { thread: []const u8, from: ?log.Cursor = null }) !void {
    try connection.following.follow(connection.clients.runtime, arena, given.thread, given.from);
    return connection.answer(arena, id, nothing);
}

fn threadsUnfollow(connection: *Connection, arena: Allocator, id: []const u8, given: struct { thread: []const u8 }) !void {
    connection.following.unfollow(given.thread);
    return connection.answer(arena, id, nothing);
}

/// The list of threads watched: answered with every thread's row as it stands, then sent a row of each as it changes, as
/// a list is read and then watched from the version it was read at.
fn threadsWatch(connection: *Connection, arena: Allocator, id: []const u8, _: struct {}) !void {
    const rows = try threads.list(connection.clients.runtime, arena);
    try connection.following.watchThreads(arena, rows);
    return connection.answer(arena, id, .{ .threads = rows });
}

fn threadsUnwatch(connection: *Connection, arena: Allocator, id: []const u8, _: struct {}) !void {
    connection.following.unwatchThreads();
    return connection.answer(arena, id, nothing);
}

/// The settings as they stand — the environment's, and this client's device's — then each change of them.
fn settingsWatch(connection: *Connection, arena: Allocator, id: []const u8, _: struct {}) !void {
    const now = try Following.settingsOf(connection.clients.runtime, arena, connection.principal.?.session);
    try connection.following.watchSettings(arena, now);
    return connection.answer(arena, id, now);
}

fn settingsUnwatch(connection: *Connection, arena: Allocator, id: []const u8, _: struct {}) !void {
    connection.following.unwatchSettings();
    return connection.answer(arena, id, nothing);
}

/// The settings changed: the environment's, which are every client's and change what threads are made with, as one that
/// operates the threads may; this client's device's, which are its own.
fn settingsSet(connection: *Connection, arena: Allocator, id: []const u8, given: struct { environment: ?settings.EnvironmentChange = null, device: ?foundation.json.Raw = null }) !void {
    const principal = connection.principal.?;
    if (given.environment != null and !principal.allows(.@"threads.operate")) return error.EnvironmentNotOperated;
    try settings.set(connection.clients.runtime, arena, principal.session, .{ .environment = given.environment, .device = given.device });
    return connection.answer(arena, id, nothing);
}

/// A key set for a provider, kept by the host from then on.
fn credentialsSet(connection: *Connection, arena: Allocator, id: []const u8, given: struct { provider: []const u8, api_key: []const u8 }) !void {
    const store = try connection.credentialsOf(arena, given.provider);
    var setting: Setting = .{ .key = given.api_key };
    _ = store.modify(arena, given.provider, .{ .context = &setting, .apply = Setting.apply }) catch return error.CredentialNotKept;
    return connection.answer(arena, id, nothing);
}

/// A provider's credential removed, the host keeping none: one it reads elsewhere, as from its environment, is read as
/// before.
fn credentialsRemove(connection: *Connection, arena: Allocator, id: []const u8, given: struct { provider: []const u8 }) !void {
    const store = try connection.credentialsOf(arena, given.provider);
    store.remove(given.provider) catch return error.CredentialNotForgotten;
    return connection.answer(arena, id, nothing);
}

/// The models a thread may run with: the text models of the providers' directory, each as the catalogue describes it.
fn modelsList(connection: *Connection, arena: Allocator, id: []const u8, _: struct {}) !void {
    return connection.answer(arena, id, .{ .models = try connection.clients.models.list(arena, .text) });
}

/// A session, as the access methods show it: as the host keeps it, and whether a client connected now holds it, and
/// whether it is this client's.
const SessionShown = struct {
    id: []const u8,
    method: Access.Method,
    scopes: []const Access.Scope,
    label: ?[]const u8 = null,
    issued_at: i64,
    expires_at: i64,
    connected: bool,
    current: bool,
};

/// The host's sessions, each marked where a client connected now holds it and where it is this client's, and the links
/// that pair new clients — none of their secrets.
fn accessList(connection: *Connection, arena: Allocator, id: []const u8, _: struct {}) !void {
    const access = connection.clients.access orelse return error.NoAccess;
    const listed = try access.list(arena);
    const shown = try arena.alloc(SessionShown, listed.sessions.len);
    for (listed.sessions, shown) |session, *each| each.* = .{
        .id = session.id,
        .method = session.method,
        .scopes = session.scopes,
        .label = session.label,
        .issued_at = session.issued_at,
        .expires_at = session.expires_at,
        .connected = connection.clients.holdsSession(session.id),
        .current = connection.holds(session.id),
    };
    return connection.answer(arena, id, .{ .sessions = shown, .links = listed.links });
}

/// A link that pairs one new client while it lasts, granting the scopes asked — at most what this client's session
/// grants, as one delegates no more than it holds; all of those where none are asked: its secret, handed once.
fn accessPair(connection: *Connection, arena: Allocator, id: []const u8, given: struct { label: ?[]const u8 = null, scopes: ?[]const Access.Scope = null }) !void {
    const access = connection.clients.access orelse return error.NoAccess;
    const principal = connection.principal.?;
    const scopes = given.scopes orelse principal.scopes;
    for (scopes) |scope| if (!principal.allows(scope)) return error.WiderThanSession;
    return connection.answer(arena, id, try access.pair(arena, given.label, scopes));
}

/// A session revoked — each client that holds it let go, after it is answered — or a link that pairs, by its id.
fn accessRevoke(connection: *Connection, arena: Allocator, id: []const u8, given: struct { id: []const u8 }) !void {
    const access = connection.clients.access orelse return error.NoAccess;
    const revoked = try access.revoke(arena, given.id);
    if (revoked == .none) return error.NoSuchAccess;
    if (revoked == .session) {
        // A session revoked holds no device: what its device set goes with it.
        var changes: runtime_.Changes = .{ .arena = arena };
        try settings.forget(connection.clients.runtime, &changes, arena, given.id);
        if (changes.items().len > 0) _ = try connection.clients.runtime.commit(&changes);
    }
    try connection.answer(arena, id, .{ .revoked = revoked });
    if (revoked == .session) connection.clients.dropSession(given.id);
}

/// The credentials the host keeps, where `provider` is one of the models' providers, whose credential a method changes.
fn credentialsOf(connection: *Connection, arena: Allocator, provider: []const u8) !ai.driver.Credentials {
    const store = connection.clients.credentials orelse return error.NoCredentials;
    for (try connection.clients.models.providerIds(arena)) |known| {
        if (std.mem.eql(u8, known, provider)) return store;
    }
    return error.UnknownProvider;
}

/// A change of a provider's credential to the key `key`, whatever it was.
const Setting = struct {
    key: []const u8,

    fn apply(context: *anyopaque, _: Allocator, _: ?ai.driver.Credential) ai.failure.Error!?ai.driver.Credential {
        const setting: *Setting = @ptrCast(@alignCast(context));
        return .{ .api_key = setting.key };
    }
};

/// Greets the client where it speaks the protocol's version and holds a session: its answer the session's id and
/// scopes; one that holds none is told so.
fn hello(connection: *Connection, arena: Allocator, id: []const u8, given: struct { protocol: u32 }) !void {
    if (given.protocol != protocol) return error.OtherProtocol;
    const principal = connection.principal orelse return error.NoSession;
    connection.greeted = true;
    // The environment the client reached: the machine the node runs on, by its name.
    const environment: ?struct { name: []const u8 } = if (connection.clients.machine.name) |name| .{ .name = name } else null;
    return connection.answer(arena, id, .{ .protocol = protocol, .session = principal.session, .scopes = principal.scopes, .environment = environment });
}

/// Answers the method `id` with `result`, after what the method changed of what the client follows — fed first, while
/// its outbox has room — so the client holds what it changed as the answer comes, as a store's reply follows the
/// invalidations its command caused.
pub fn answer(connection: *Connection, arena: Allocator, id: []const u8, result: anytype) !void {
    const Result = @TypeOf(result);
    if (@typeInfo(Result) == .@"struct" and @typeInfo(Result).@"struct".is_tuple) @compileError("an answer is an object, which a tuple is written as no more: give `nothing`");
    _ = connection.feed();
    connection.send(try foundation.json.encode(arena, .{ .id = id, .result = result }));
}

/// Refuses a message that is no message of the protocol's, as JSON-RPC answers one: by its id where the id reads,
/// whatever else in it is wrong; with a null id where it does not.
fn refuseMalformed(connection: *Connection, arena: Allocator, message: []const u8) void {
    const envelope = foundation.json.decode(struct { id: []const u8 }, arena, message) catch return connection.refuse(arena, null, "bad-message", "The message is not one of the protocol's.");
    connection.refuse(arena, envelope.id, "invalid", "A message holds its id, its method and its params alone.");
}

pub fn refuse(connection: *Connection, arena: Allocator, id: ?[]const u8, code: []const u8, message: []const u8) void {
    // An id that could not be read is written null, as JSON-RPC writes it, where an absent field would be left out.
    const told: std.json.Value = if (id) |given| .{ .string = given } else .null;
    const encoded = foundation.json.encode(arena, .{ .id = told, .@"error" = .{ .code = code, .message = message } }) catch return;
    connection.send(encoded);
}

/// Puts a copy of `message` in the outbox.
pub fn send(connection: *Connection, message: []const u8) void {
    if (connection.closed) return;
    connection.putOwned(connection.allocator.dupe(u8, message) catch return connection.close());
}

/// Puts `message` in the outbox, the taker's from then on; a client whose outbox would pass its hard bound, or is full,
/// is let go.
fn putOwned(connection: *Connection, message: []u8) void {
    if (connection.closed) return connection.allocator.free(message);
    // Counted before it is put, so the taker never takes away more than was added.
    const queued = connection.queued.fetchAdd(message.len, .seq_cst) + message.len;
    const put_count = if (queued > outbox_hard_bytes) 0 else connection.outbox.put(connection.clients.runtime.host.io, &.{message}, 0) catch 0;
    if (put_count == 1) return;
    _ = connection.queued.fetchSub(message.len, .seq_cst);
    connection.allocator.free(message);
    connection.close();
}
