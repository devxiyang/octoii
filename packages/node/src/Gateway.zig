//! The agent gateway, as the node holds it: the program beside the node's own that answers for models that come only
//! through an agent — Claude through the person's own Claude Code — run on the local machine as a coprocess, talking on
//! the descriptors 3 and 4 as JSON-RPC a line, both ways at once. It is started as a request first goes to it, and
//! again after it ended, and it serves the node's network at `gateway://`: a request there is carried whole as an `http`
//! request, and what answers it comes back by its id — `http/head`, its status and headers; an `http/body` for each
//! piece of its body as it comes; then the request's result, its end, or its error, where no response could be made. A
//! response let go before its end cancels its request. Every other address goes to the rest of the network. A gateway
//! that stood idle — no request open on it, none sent it — past its while is stopped, as the node alone knows nothing
//! is on its way to it, and started again by the next request.
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
/// The gateway as it runs, held by the node; none before the first request, or once it was stopped.
running: ?*Running = null,
/// The id of the request sent last.
sent: std.atomic.Value(i64) = .init(0),
/// How long the gateway may stand idle before it is stopped.
idle_ms: u64,
/// What stops the gateway once it stood idle: from its first start till the gateway is let go.
watching: ?Io.Future(void) = null,

/// Where the gateway answers, as the drivers address it.
pub const scheme = "gateway://";

pub const Options = struct {
    io: Io,
    /// The machine it runs on: the node's own.
    machine: h.beak_handle,
    program: []const u8,
    state: []const u8,
    rest: transport.Http,
    /// Past the while its agents keep a session unasked, so stopping it ends none in use.
    idle_ms: u64 = 15 * std.time.ms_per_min,
};

pub fn init(gpa: Allocator, options: Options) Gateway {
    return .{ .gpa = gpa, .io = options.io, .machine = options.machine, .program = options.program, .state = options.state, .rest = options.rest, .idle_ms = options.idle_ms };
}

/// Lets the gateway go: stopped once the last response open on it is let go too.
pub fn deinit(gateway: *Gateway) void {
    if (gateway.watching) |*watching| watching.cancel(gateway.io);
    gateway.watching = null;
    if (gateway.running) |running| running.release();
    gateway.running = null;
}

pub fn http(gateway: *Gateway) transport.Http {
    return .{ .context = gateway, .vtable = &.{ .send = send } };
}

/// The gateway as it runs: its line peer, held by the node and by each response open on it, and closed — the process
/// stopped — as the last lets it go; and when a request last went to it or ended.
const Running = struct {
    gpa: Allocator,
    io: Io,
    lines: *Lines,
    holders: std.atomic.Value(usize) = .init(1),
    /// On the io's awake clock, in milliseconds.
    used_ms: std.atomic.Value(i64),

    fn hold(running: *Running) *Running {
        running.used();
        _ = running.holders.fetchAdd(1, .monotonic);
        return running;
    }

    fn release(running: *Running) void {
        running.used();
        if (running.holders.fetchSub(1, .acq_rel) != 1) return;
        running.lines.close();
        running.gpa.destroy(running);
    }

    fn used(running: *Running) void {
        running.used_ms.store(Io.Clock.awake.now(running.io).toMilliseconds(), .monotonic);
    }

    /// Whether it stood idle `idle_ms`: no response open on it, none begun or ended since.
    fn isIdle(running: *Running, idle_ms: u64) bool {
        if (running.holders.load(.acquire) != 1) return false;
        return Io.Clock.awake.now(running.io).toMilliseconds() - running.used_ms.load(.monotonic) >= idle_ms;
    }
};

/// The gateway running, held for a request: started where it is not yet, or ended; null where it could not be, why
/// logged.
fn held(gateway: *Gateway) Allocator.Error!?*Running {
    gateway.lock.lockUncancelable(gateway.io);
    defer gateway.lock.unlock(gateway.io);
    if (gateway.running) |running| {
        if (!running.lines.isClosed()) return running.hold();
        gateway.running = null;
        running.release();
    }
    const running = try gateway.started() orelse return null;
    gateway.running = running;
    if (gateway.watching == null) gateway.watching = gateway.io.concurrent(watchIdle, .{gateway}) catch null;
    return running.hold();
}

/// Stops the gateway each time it stood idle past its while, till the gateway is let go.
fn watchIdle(gateway: *Gateway) void {
    const every_ms = @max(gateway.idle_ms / 4, 1);
    while (true) {
        gateway.io.sleep(.fromMilliseconds(@intCast(every_ms)), .awake) catch return;
        gateway.stopIdle();
    }
}

/// Stops the gateway where it stood idle past its while: its process asked to end by its input's end, none of its
/// requests open, and none on its way to it while the lock is held.
fn stopIdle(gateway: *Gateway) void {
    gateway.lock.lockUncancelable(gateway.io);
    defer gateway.lock.unlock(gateway.io);
    const running = gateway.running orelse return;
    if (!running.isIdle(gateway.idle_ms)) return;
    gateway.running = null;
    running.release();
}

/// The gateway started on the machine, talked to on its channel; null where it could not be, why logged.
fn started(gateway: *Gateway) Allocator.Error!?*Running {
    var scratch_arena: std.heap.ArenaAllocator = .init(gateway.gpa);
    defer scratch_arena.deinit();
    const coprocess = switch (try Coprocess.start(gateway.gpa, scratch_arena.allocator(), .{
        .io = gateway.io,
        .machine = gateway.machine,
        .argv = &.{ gateway.program, "--state", gateway.state },
        .cwd = gateway.state,
        .channel = .{ .input = 3, .output = 4 },
        .name = "the agent gateway",
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
    running.* = .{ .gpa = gateway.gpa, .io = gateway.io, .lines = lines, .used_ms = .init(Io.Clock.awake.now(gateway.io).toMilliseconds()) };
    return running;
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
    const running = try gateway.held() orelse return error.Transport;
    errdefer running.release();
    const exchange = try gateway.gpa.create(Exchange);
    errdefer gateway.gpa.destroy(exchange);
    exchange.* = .{ .arena = .init(gateway.gpa), .piece_arena = .init(gateway.gpa), .running = running, .sent = undefined, .idle_ms = if (request.wait) |wait| wait.idle_ms else null, .reader = undefined };
    errdefer exchange.piece_arena.deinit();
    errdefer exchange.arena.deinit();
    const arena = exchange.arena.allocator();
    exchange.reader = .{ .vtable = &.{ .stream = Exchange.stream }, .buffer = try arena.alloc(u8, 16 * 1024), .seek = 0, .end = 0 };
    exchange.sent = try gateway.carry(running, request) orelse return error.Transport;
    errdefer exchange.end();
    const head = try exchange.headOf(arena, if (request.wait) |wait| wait.head_ms else null);
    return .{ .status = head.status, .headers = head.headers, .body = &exchange.reader, .context = exchange, .vtable = &.{ .failure = Exchange.failure, .close = Exchange.close } };
}

/// Sends `request` to the gateway as the channel carries it: its exchange; null where it could not be written, why
/// logged. What it is written in is let go once it is.
fn carry(gateway: *Gateway, running: *Running, request: transport.Request) Allocator.Error!?Lines.Exchange {
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
    // `gateway://claude/v1/messages` is the path `/claude/v1/messages` on the gateway.
    try params.put(arena, "path", .{ .string = request.url[scheme.len - 1 ..] });
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

    /// Whether the gateway runs, as the node holds it.
    fn isRunning(played: *Played) bool {
        played.gateway.lock.lockUncancelable(std.testing.io);
        defer played.gateway.lock.unlock(std.testing.io);
        return played.gateway.running != null;
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
    try std.testing.expectEqualStrings("started\n", try played.writtenDown(arena, "starts"));
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
    try std.testing.expectEqualStrings("started\nstarted\n", try played.writtenDown(arena, "starts"));
}

test "a gateway that stood idle past its while is stopped, and started again by the next request" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var played: Played = undefined;
    try played.open(arena, null);
    defer played.close();
    played.gateway.idle_ms = 40;
    const first = try played.send("gateway://claude/v1/models");
    _ = try first.body.allocRemaining(arena, .unlimited);
    // Open, it is not idle, however long it stands.
    try std.testing.io.sleep(.fromMilliseconds(120), .awake);
    try std.testing.expect(played.isRunning());
    first.close();
    try std.testing.io.sleep(.fromMilliseconds(200), .awake);
    try std.testing.expect(!played.isRunning());
    const again = try played.send("gateway://claude/v1/models");
    defer again.close();
    _ = try again.body.allocRemaining(arena, .unlimited);
    try std.testing.expectEqualStrings("started\nstarted\n", try played.writtenDown(arena, "starts"));
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
