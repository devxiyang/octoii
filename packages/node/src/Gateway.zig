//! The agent gateway, as the node holds it: the program beside the node's own that answers for models that come only
//! through an agent — Claude through the person's own Claude Code — run on the local machine as a coprocess, talking on
//! the descriptors 3 and 4 as JSON-RPC a line, both ways at once. It is started as a request first goes to it, and
//! again after it ended, and it serves the node's network at `gateway://`: a request there is carried whole as an `http`
//! request, and what answers it comes back by its id — `http/head`, its status and headers; an `http/body` for each
//! piece of its body as it comes; then the request's result, its end, or its error, where no response could be made. A
//! response let go before its end cancels its request. Every other address goes to the rest of the network. Once
//! started, the gateway stays up as the browser does; its agents reclaim what of them stands idle themselves. An
//! account the person added of an agent's has a gateway of its own, which keeps the account's logins apart from the
//! person's own, and what lasts beside them: `gateway://claude/accounts/{id}/v1/messages` is `/claude/v1/messages` on
//! the gateway of the account `id`. `DELETE gateway://claude/accounts/{id}` lets the account go, as the person removed
//! it: its agent signed out on its gateway, `DELETE /claude/v1/account`, whose response answers; the gateway stopped as
//! the last response open on it is let go, and what it kept deleted then.
const Gateway = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const siphon = @import("siphon");
const transport = siphon.foundation.http;
const jsonrpc = siphon.foundation.jsonrpc;
const Lines = jsonrpc.Lines;
const Coprocess = siphon.tools.Coprocess;
const h = siphon.beak.h;

const log = std.log.scoped(.gateway);

gpa: Allocator,
io: Io,
machine: h.beak_handle,
/// The gateway's program and the folder it keeps what lasts in, by their absolute paths.
program: []const u8,
state: []const u8,
/// Where every other address goes.
rest: transport.Http,
/// One start at a time.
lock: Io.Mutex = .init,
/// The gateways running, each held by the node, by the account each answers for: the empty name for the person's own.
running: std.StringArrayHashMapUnmanaged(*Running) = .empty,
/// The id of the request sent last.
sent: std.atomic.Value(i64) = .init(0),

/// Where the gateway answers, as the drivers address it.
pub const scheme = "gateway://";

pub const Options = struct {
    io: Io,
    /// The machine it runs on: the node's own.
    machine: h.beak_handle,
    program: []const u8,
    state: []const u8,
    rest: transport.Http,
};

pub fn init(gpa: Allocator, options: Options) Gateway {
    return .{ .gpa = gpa, .io = options.io, .machine = options.machine, .program = options.program, .state = options.state, .rest = options.rest };
}

/// Lets the gateways go: each stopped once the last response open on it is let go too.
pub fn deinit(gateway: *Gateway) void {
    for (gateway.running.keys(), gateway.running.values()) |account, running| {
        running.release();
        gateway.gpa.free(account);
    }
    gateway.running.deinit(gateway.gpa);
}

pub fn http(gateway: *Gateway) transport.Http {
    return .{ .context = gateway, .vtable = &.{ .send = send } };
}

/// The gateway as it runs: its line peer, held by the node and by each response open on it, and closed — the process
/// stopped — as the last lets it go; the folder of an account let go of deleted then.
const Running = struct {
    gpa: Allocator,
    io: Io,
    lines: *Lines,
    holders: std.atomic.Value(usize) = .init(1),
    /// The folder of the account the gateway answered for, where the account was let go of: deleted as it stops.
    forgotten: ?[]const u8 = null,

    fn hold(running: *Running) *Running {
        _ = running.holders.fetchAdd(1, .monotonic);
        return running;
    }

    fn release(running: *Running) void {
        if (running.holders.fetchSub(1, .acq_rel) != 1) return;
        running.lines.close();
        if (running.forgotten) |folder| {
            Io.Dir.cwd().deleteTree(running.io, folder) catch |err| log.warn("what the gateway of an account let go of kept stays at {s}: {s}", .{ folder, @errorName(err) });
            running.gpa.free(folder);
        }
        running.gpa.destroy(running);
    }
};

/// The gateway of `account` running, held for a request: started where it is not yet, or ended; null where it could not
/// be, why logged.
fn held(gateway: *Gateway, account: []const u8) Allocator.Error!?*Running {
    gateway.lock.lockUncancelable(gateway.io);
    defer gateway.lock.unlock(gateway.io);
    if (gateway.running.get(account)) |running| {
        if (!running.lines.isClosed()) return running.hold();
        const ended = gateway.running.fetchSwapRemove(account).?;
        gateway.gpa.free(ended.key);
        ended.value.release();
    }
    try gateway.running.ensureUnusedCapacity(gateway.gpa, 1);
    const key = try gateway.gpa.dupe(u8, account);
    errdefer gateway.gpa.free(key);
    const running = try gateway.started(account) orelse {
        gateway.gpa.free(key);
        return null;
    };
    gateway.running.putAssumeCapacity(key, running);
    return running.hold();
}

/// The gateway of `account` started on the machine, talked to on its channel; null where it could not be, why logged.
/// An added account's keeps what lasts in `accounts/{id}` of the gateway's folder, and the agents' logins of the
/// account in its `logins`.
fn started(gateway: *Gateway, account: []const u8) Allocator.Error!?*Running {
    var scratch_arena: std.heap.ArenaAllocator = .init(gateway.gpa);
    defer scratch_arena.deinit();
    const arena = scratch_arena.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    if (account.len == 0) {
        try argv.appendSlice(arena, &.{ gateway.program, "--state", gateway.state });
    } else {
        const state = try gateway.accountFolder(arena, account);
        try argv.appendSlice(arena, &.{ gateway.program, "--state", state, "--logins", try std.fs.path.join(arena, &.{ state, "logins" }) });
    }
    const coprocess = switch (try Coprocess.start(gateway.gpa, arena, .{
        .io = gateway.io,
        .machine = gateway.machine,
        .argv = argv.items,
        .cwd = gateway.state,
        .channel = .{ .input = 3, .output = 4 },
        .name = if (account.len == 0) "the agent gateway" else try arena.print("the agent gateway of the account {s}", .{account}),
    })) {
        .coprocess => |coprocess| coprocess,
        .failed => |why| {
            log.warn("{s}", .{why});
            return null;
        },
    };
    const lines = Lines.start(gateway.gpa, .{ .io = gateway.io }, coprocess.process(), relatedOf) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unconcurrent => {
            log.warn("the node's io runs nothing concurrently, which talking to the agent gateway needs", .{});
            return null;
        },
    };
    errdefer lines.close();
    const running = try gateway.gpa.create(Running);
    errdefer gateway.gpa.destroy(running);
    running.* = .{ .gpa = gateway.gpa, .io = gateway.io, .lines = lines };
    return running;
}

/// The folder an added account's gateway keeps what lasts in, in `arena`.
fn accountFolder(gateway: *const Gateway, arena: Allocator, account: []const u8) Allocator.Error![]const u8 {
    return std.fs.path.join(arena, &.{ gateway.state, "accounts", account });
}

/// Which request a message of the gateway's is for: a response by the request it answers; a notification by the id it
/// names.
fn relatedOf(message: jsonrpc.Message) ?jsonrpc.Id {
    if (message.answers()) |id| return id;
    const notification = switch (message) {
        .notification => |notification| notification,
        else => return null,
    };
    const params = notification.params orelse return null;
    if (params != .object) return null;
    return jsonrpc.Id.of(params.object.get("id") orelse return null);
}

fn send(context: *anyopaque, request: transport.Request) transport.SendError!transport.Response {
    const gateway: *Gateway = @ptrCast(@alignCast(context));
    if (!std.mem.startsWith(u8, request.url, scheme)) return gateway.rest.send(request);
    var scratch_arena: std.heap.ArenaAllocator = .init(gateway.gpa);
    defer scratch_arena.deinit();
    const arena = scratch_arena.allocator();
    switch (try addressed(arena, request.url) orelse return refused(request)) {
        .on => |on| {
            const running = try gateway.held(on.account) orelse return error.Transport;
            return gateway.respond(running, request, on.path);
        },
        .account => |account| {
            if (request.method != .DELETE) return refused(request);
            return gateway.forgetAccount(arena, account.agent, account.id, request);
        },
    }
}

/// That no gateway answers `request`, logged.
fn refused(request: transport.Request) transport.SendError {
    log.warn("no gateway answers {s} {s}", .{ @tagName(request.method), request.url });
    return error.Transport;
}

/// Lets the account `id` of `agent`'s go, as the person removed it: its agent signed out on its gateway, whose response
/// answers; the gateway, the node's no more, stopped as the last response open on it is let go, and its folder deleted.
fn forgetAccount(gateway: *Gateway, arena: Allocator, agent: []const u8, id: []const u8, request: transport.Request) transport.SendError!transport.Response {
    const running = try gateway.held(id) orelse return error.Transport;
    gateway.letGo(id) catch |err| {
        running.release();
        return err;
    };
    const signing_out: transport.Request = .{ .method = .DELETE, .url = request.url, .headers = &.{}, .wait = request.wait };
    return gateway.respond(running, signing_out, try arena.print("/{s}/v1/account", .{agent}));
}

/// Has the node let go of the gateway of the account `id`: its folder deleted once the gateway stops, as the last that
/// holds it lets it go.
fn letGo(gateway: *Gateway, id: []const u8) Allocator.Error!void {
    gateway.lock.lockUncancelable(gateway.io);
    defer gateway.lock.unlock(gateway.io);
    const running = gateway.running.get(id) orelse return;
    running.forgotten = try gateway.accountFolder(gateway.gpa, id);
    const kept = gateway.running.fetchSwapRemove(id).?;
    gateway.gpa.free(kept.key);
    kept.value.release();
}

/// What answers `request` on the gateway `running`, a hold of which it takes, at `path` there.
fn respond(gateway: *Gateway, running: *Running, request: transport.Request, path: []const u8) transport.SendError!transport.Response {
    errdefer running.release();
    const exchange = try gateway.gpa.create(Exchange);
    errdefer gateway.gpa.destroy(exchange);
    exchange.* = .{ .arena = .init(gateway.gpa), .piece_arena = .init(gateway.gpa), .running = running, .sent = undefined, .idle_ms = if (request.wait) |wait| wait.idle_ms else null, .reader = undefined };
    errdefer exchange.piece_arena.deinit();
    errdefer exchange.arena.deinit();
    const arena = exchange.arena.allocator();
    exchange.reader = .{ .vtable = &.{ .stream = Exchange.stream }, .buffer = try arena.alloc(u8, 16 * 1024), .seek = 0, .end = 0 };
    exchange.sent = try gateway.carry(running, request, path) orelse return error.Transport;
    errdefer exchange.end();
    const head = try exchange.headOf(arena, if (request.wait) |wait| wait.head_ms else null);
    return .{ .status = head.status, .headers = head.headers, .body = &exchange.reader, .context = exchange, .vtable = &.{ .failure = Exchange.failure, .close = Exchange.close } };
}

/// Where a request at the gateway's address goes: a path on the gateway of an account — the empty name for the
/// person's own — or an account the person added of an agent's, itself.
const Addressed = union(enum) {
    on: struct { account: []const u8, path: []const u8 },
    account: struct { agent: []const u8, id: []const u8 },
};

/// `gateway://claude/v1/messages` is `/claude/v1/messages` on the person's own gateway, and
/// `gateway://claude/accounts/{id}/v1/messages` on the gateway of the account `id`, in `arena`;
/// `gateway://claude/accounts/{id}` is the account itself; null for an address no gateway answers.
fn addressed(arena: Allocator, url: []const u8) Allocator.Error!?Addressed {
    const path = url[scheme.len - 1 ..];
    const agent_end = std.mem.indexOfScalarPos(u8, path, 1, '/') orelse return .{ .on = .{ .account = "", .path = path } };
    const marker = "/accounts/";
    if (!std.mem.startsWith(u8, path[agent_end..], marker)) return .{ .on = .{ .account = "", .path = path } };
    const tail = path[agent_end + marker.len ..];
    const id_end = std.mem.indexOfScalar(u8, tail, '/') orelse tail.len;
    const account = tail[0..id_end];
    if (account.len == 0) return null;
    for (account) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-') return null;
    if (id_end == tail.len) return .{ .account = .{ .agent = path[1..agent_end], .id = account } };
    return .{ .on = .{ .account = account, .path = try std.mem.concat(arena, u8, &.{ path[0..agent_end], tail[id_end..] }) } };
}

/// Sends `request` to the gateway at `path` as the channel carries it: its exchange; null where it could not be
/// written, why logged. What it is written in is let go once it is.
fn carry(gateway: *Gateway, running: *Running, request: transport.Request, path: []const u8) Allocator.Error!?Lines.Exchange {
    var scratch_arena: std.heap.ArenaAllocator = .init(gateway.gpa);
    defer scratch_arena.deinit();
    const arena = scratch_arena.allocator();
    var headers: std.json.Array = .init(arena);
    for (request.headers) |header| {
        var pair: std.json.Array = .init(arena);
        try pair.appendSlice(&.{ .{ .string = header.name }, .{ .string = header.value } });
        try headers.append(.{ .array = pair });
    }
    var params: std.json.ObjectMap = .empty;
    try params.put(arena, "method", .{ .string = @tagName(request.method) });
    try params.put(arena, "path", .{ .string = path });
    try params.put(arena, "headers", .{ .array = headers });
    if (request.body) |body| try params.put(arena, "body", .{ .string = body });
    const id: jsonrpc.Id = .{ .number = gateway.sent.fetchAdd(1, .monotonic) + 1 };
    return switch (try running.lines.request(arena, .{ .id = id, .method = "http", .params = .{ .object = params } })) {
        .exchange => |sent| sent,
        .unwritten => |why| {
            log.warn("{s}", .{why});
            return null;
        },
    };
}

/// A request carried to the gateway and what answers it, alive till its response is let go.
const Exchange = struct {
    /// What lasts as long as the response: its headers and its reader's buffer.
    arena: std.heap.ArenaAllocator,
    /// What the piece of the body being read is in, made again for each.
    piece_arena: std.heap.ArenaAllocator,
    running: *Running,
    sent: Lines.Exchange,
    idle_ms: ?u64,
    reader: Io.Reader,
    /// What of the piece the reader has not yet taken.
    piece: []const u8 = "",
    /// Whether the gateway said the request's last word, its result or its error: nothing of it to cancel.
    answered: bool = false,
    /// Whether the body ended: its result came.
    ended: bool = false,
    /// Why the body broke off, where it did.
    failed: ?transport.Error = null,

    const Head = struct { status: u16, headers: []const transport.Header };

    /// The response's head, waiting at most `wait_ms` for it, in `arena`.
    fn headOf(exchange: *Exchange, arena: Allocator, wait_ms: ?u64) transport.SendError!Head {
        while (true) {
            const message = switch (try exchange.next(arena, wait_ms)) {
                .message => |message| message,
                .ended => |why| return why,
            };
            switch (message) {
                .notification => |notification| if (std.mem.eql(u8, notification.method, "http/head")) {
                    return try headIn(arena, notification.params) orelse {
                        log.warn("the agent gateway answered with a head that is none", .{});
                        return error.Transport;
                    };
                },
                .failure => |failed| {
                    exchange.answered = true;
                    log.warn("the agent gateway could not answer: {s}", .{failed.@"error".message});
                    return error.Transport;
                },
                .result => {
                    exchange.answered = true;
                    log.warn("the agent gateway ended a request before its head", .{});
                    return error.Transport;
                },
                // The gateway asks the node nothing.
                .request => {},
            }
        }
    }

    /// What the next wait for a message of the request came to: the message, or how the request ended without one.
    const Next = union(enum) { message: jsonrpc.Message, ended: transport.Error };

    fn next(exchange: *Exchange, arena: Allocator, wait_ms: ?u64) Allocator.Error!Next {
        const incoming = exchange.sent.next(arena, wait_ms) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => .{ .ended = error.Canceled },
        };
        return switch (incoming) {
            .message => |arrived| .{ .message = arrived.message },
            .quiet => .{ .ended = error.Timeout },
            .closed => |why| {
                exchange.answered = true;
                log.warn("{s}", .{why orelse "the agent gateway was stopped"});
                return .{ .ended = error.Transport };
            },
        };
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const exchange: *Exchange = @fieldParentPtr("reader", r);
        while (exchange.piece.len == 0) {
            if (exchange.failed != null) return error.ReadFailed;
            if (exchange.ended) return error.EndOfStream;
            try exchange.nextPiece();
        }
        const written = try w.write(limit.sliceConst(exchange.piece));
        exchange.piece = exchange.piece[written..];
        return written;
    }

    /// Waits for the next piece of the body, at most the request's idle wait, the last piece let go: the body's end,
    /// where its result came; `ReadFailed`, why kept, where it broke off.
    fn nextPiece(exchange: *Exchange) error{ReadFailed}!void {
        _ = exchange.piece_arena.reset(.retain_capacity);
        const arena = exchange.piece_arena.allocator();
        while (true) {
            const message = switch (exchange.next(arena, exchange.idle_ms) catch return exchange.broke(error.Transport)) {
                .message => |message| message,
                .ended => |why| return exchange.broke(why),
            };
            switch (message) {
                .notification => |notification| if (std.mem.eql(u8, notification.method, "http/body")) {
                    exchange.piece = dataIn(notification.params) orelse return exchange.broke(error.Transport);
                    return;
                },
                .result => {
                    exchange.answered = true;
                    exchange.ended = true;
                    return;
                },
                .failure => |failed| {
                    exchange.answered = true;
                    log.warn("the agent gateway broke off a body: {s}", .{failed.@"error".message});
                    return exchange.broke(error.Transport);
                },
                .request => {},
            }
        }
    }

    fn broke(exchange: *Exchange, why: transport.Error) error{ReadFailed} {
        exchange.failed = why;
        return error.ReadFailed;
    }

    fn failure(context: *anyopaque) transport.Error {
        const exchange: *Exchange = @ptrCast(@alignCast(context));
        return exchange.failed orelse error.Transport;
    }

    /// Lets the request go: cancelled where the gateway has not said its last word of it.
    fn end(exchange: *Exchange) void {
        if (exchange.answered) exchange.sent.close() else exchange.sent.cancel("the response was let go before its end");
    }

    /// Lets the response go, its request ended, and the gateway's hold.
    fn close(context: *anyopaque) void {
        const exchange: *Exchange = @ptrCast(@alignCast(context));
        exchange.end();
        exchange.running.release();
        exchange.piece_arena.deinit();
        const gpa = exchange.arena.child_allocator;
        exchange.arena.deinit();
        gpa.destroy(exchange);
    }
};

/// The status and headers of `http/head`'s params, in `arena`; null where they are not what the channel gives.
fn headIn(arena: Allocator, params: ?std.json.Value) Allocator.Error!?Exchange.Head {
    const given = params orelse return null;
    if (given != .object) return null;
    const status = given.object.get("status") orelse return null;
    if (status != .integer or status.integer < 100 or status.integer > 999) return null;
    const listed = given.object.get("headers") orelse return null;
    if (listed != .array) return null;
    const headers = try arena.alloc(transport.Header, listed.array.items.len);
    for (listed.array.items, headers) |pair, *header| {
        if (pair != .array or pair.array.items.len != 2 or pair.array.items[0] != .string or pair.array.items[1] != .string) return null;
        header.* = .{ .name = try arena.dupe(u8, pair.array.items[0].string), .value = try arena.dupe(u8, pair.array.items[1].string) };
    }
    return .{ .status = @intCast(status.integer), .headers = headers };
}

/// The piece of the body `http/body`'s params carry; null where they carry none.
fn dataIn(params: ?std.json.Value) ?[]const u8 {
    const given = params orelse return null;
    if (given != .object) return null;
    const data = given.object.get("data") orelse return null;
    return if (data == .string) data.string else null;
}

/// The network past the gateway, as a test has it: every address it is asked for kept, none answered.
const Rest = struct {
    asked: std.ArrayList([]const u8) = .empty,
    arena: Allocator,

    fn network(rest: *Rest) transport.Http {
        return .{ .context = rest, .vtable = &.{ .send = sendOn } };
    }

    fn sendOn(context: *anyopaque, request: transport.Request) transport.SendError!transport.Response {
        const rest: *Rest = @ptrCast(@alignCast(context));
        try rest.asked.append(rest.arena, try rest.arena.dupe(u8, request.url));
        return error.Transport;
    }
};

/// A gateway of the played program's, keeping what lasts in a folder of the test's, on the local machine.
const Played = struct {
    tmp: std.testing.TmpDir,
    machine: h.beak_handle,
    rest: Rest,
    gateway: Gateway,
    state: []const u8,

    fn open(played: *Played, arena: Allocator, program: ?[]const u8) !void {
        played.tmp = std.testing.tmpDir(.{});
        errdefer played.tmp.cleanup();
        played.state = try played.tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
        played.machine = try siphon.testing.openLocalMachine();
        played.rest = .{ .arena = arena };
        // The build names the program from where it runs, as the machine names nothing.
        const named = program orelse try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, @import("test_options").played_gateway, arena);
        played.gateway = .init(std.testing.allocator, .{ .io = std.testing.io, .machine = played.machine, .program = named, .state = played.state, .rest = played.rest.network() });
    }

    fn close(played: *Played) void {
        played.gateway.deinit();
        _ = h.beak_close(played.machine);
        played.tmp.cleanup();
    }

    fn send(played: *Played, url: []const u8) transport.SendError!transport.Response {
        return played.gateway.http().send(.{
            .method = .POST,
            .url = url,
            .headers = &.{.{ .name = "content-type", .value = "application/json" }},
            .body = "{\"model\":\"claude-haiku-5-5\"}",
            .wait = .{ .head_ms = 10_000, .idle_ms = 10_000 },
        });
    }

    /// What the played gateway wrote down in the file `name`; nothing where it wrote nothing.
    fn writtenDown(played: *Played, arena: Allocator, name: []const u8) ![]const u8 {
        return played.tmp.dir.readFileAlloc(std.testing.io, name, arena, .unlimited) catch |err| switch (err) {
            error.FileNotFound => "",
            else => err,
        };
    }
};

test "a request at the gateway's address is carried to it on its channel, and its body streams back whole" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var played: Played = undefined;
    try played.open(arena, null);
    defer played.close();
    for (0..2) |_| {
        const response = try played.send("gateway://claude/v1/messages");
        defer response.close();
        try std.testing.expectEqual(@as(u16, 200), response.status);
        try std.testing.expectEqualStrings("text/event-stream", response.header("Content-Type").?);
        const body = try response.body.allocRemaining(arena, .unlimited);
        try std.testing.expectEqualStrings("POST /claude/v1/messages\ncontent-type: application/json\n\n{\"model\":\"claude-haiku-5-5\"}", body);
    }
    // Both went to the one gateway, started as the first went.
    try std.testing.expectEqualStrings("started, logins none\n", try played.writtenDown(arena, "starts"));
}

test "a response let go before its end cancels its request at the gateway" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var played: Played = undefined;
    try played.open(arena, null);
    defer played.close();
    const hanging = try played.send("gateway://hang");
    var piece: [7]u8 = undefined;
    try hanging.body.readSliceAll(&piece);
    try std.testing.expectEqualStrings("waiting", &piece);
    hanging.close();
    // The gateway reads in order: once a later request is answered, the cancel before it was read.
    const later = try played.send("gateway://claude/v1/models");
    defer later.close();
    _ = try later.body.allocRemaining(arena, .unlimited);
    try std.testing.expectEqualStrings("1\n", try played.writtenDown(arena, "cancelled"));
}

test "a gateway that ended breaks off its response, and the next request starts it again" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var played: Played = undefined;
    try played.open(arena, null);
    defer played.close();
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    const exiting = try played.send("gateway://exit");
    try std.testing.expectError(error.ReadFailed, exiting.body.allocRemaining(arena, .unlimited));
    try std.testing.expectEqual(error.Transport, exiting.failure());
    exiting.close();
    const again = try played.send("gateway://claude/v1/models");
    defer again.close();
    try std.testing.expectEqualStrings("POST /claude/v1/models\n", (try again.body.allocRemaining(arena, .unlimited))[0..23]);
    try std.testing.expectEqualStrings("started, logins none\nstarted, logins none\n", try played.writtenDown(arena, "starts"));
}

test "an added account's requests go to a gateway of its own, which keeps the account's logins apart" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var played: Played = undefined;
    try played.open(arena, null);
    defer played.close();
    const own = try played.send("gateway://claude/v1/models");
    defer own.close();
    _ = try own.body.allocRemaining(arena, .unlimited);
    const work = try played.send("gateway://claude/accounts/01a1c11e-f9f4-7a31/v1/models");
    defer work.close();
    try std.testing.expectEqualStrings("POST /claude/v1/models\n", (try work.body.allocRemaining(arena, .unlimited))[0..23]);
    const logins = try std.fs.path.join(arena, &.{ played.state, "accounts", "01a1c11e-f9f4-7a31", "logins" });
    try std.testing.expectEqualStrings(try arena.print("started, logins {s}\n", .{logins}), try played.writtenDown(arena, "accounts/01a1c11e-f9f4-7a31/starts"));
    try std.testing.expectEqualStrings("started, logins none\n", try played.writtenDown(arena, "starts"));
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    try std.testing.expectError(error.Transport, played.send("gateway://claude/accounts/../v1/models"));
}

test "an account let go of signs its agent out on its gateway, which then stops, what it kept deleted" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var played: Played = undefined;
    try played.open(arena, null);
    defer played.close();
    const work = try played.send("gateway://claude/accounts/01a1c11e-f9f4-7a31/v1/models");
    _ = try work.body.allocRemaining(arena, .unlimited);
    work.close();
    const own = try played.send("gateway://claude/v1/models");
    _ = try own.body.allocRemaining(arena, .unlimited);
    own.close();
    const forgotten = try played.gateway.http().send(.{ .method = .DELETE, .url = "gateway://claude/accounts/01a1c11e-f9f4-7a31", .headers = &.{}, .wait = .{ .head_ms = 10_000, .idle_ms = 10_000 } });
    try std.testing.expectEqualStrings("DELETE /claude/v1/account\n", (try forgotten.body.allocRemaining(arena, .unlimited))[0..26]);
    // The gateway stops, and its folder goes, as the response is let go.
    try std.testing.expect(played.tmp.dir.access(std.testing.io, "accounts/01a1c11e-f9f4-7a31", .{}) != error.FileNotFound);
    forgotten.close();
    try std.testing.expectError(error.FileNotFound, played.tmp.dir.access(std.testing.io, "accounts/01a1c11e-f9f4-7a31", .{}));
    // The person's own gateway stands as it was; an account itself is only let go of.
    const again = try played.send("gateway://claude/v1/models");
    defer again.close();
    _ = try again.body.allocRemaining(arena, .unlimited);
    try std.testing.expectEqualStrings("started, logins none\n", try played.writtenDown(arena, "starts"));
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    try std.testing.expectError(error.Transport, played.send("gateway://claude/accounts/01a1c11e-f9f4-7a31"));
}

test "every other address goes to the rest of the network, and a gateway that cannot start fails as the network does" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var played: Played = undefined;
    try played.open(arena, "/nonexistent/octoii-agent-gateway");
    defer played.close();
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    try std.testing.expectError(error.Transport, played.send("https://api.anthropic.com/v1/models"));
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/models", played.rest.asked.items[0]);
    try std.testing.expectError(error.Transport, played.send("gateway://claude/v1/models"));
    try std.testing.expectEqual(@as(usize, 1), played.rest.asked.items.len);
}
