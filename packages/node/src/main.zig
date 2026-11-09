//! The node: Octoii's native host, the `octoii` program. It keeps a Home — the volume, and what the host keeps beside it
//! — gives Siphon this computer's platform — the volume on Beak's log in the Home, the network, the local machine, the
//! providers' keys from the login environment — and runs what a person asks:
//!
//!     octoii serve [--home <dir>] [--port <port>] [--app <dir>] [--relay <url>]
//!         Siphon's loop run, and its protocol served to clients on the loopback address — with the web app's files,
//!         where they are given, and a link that pairs a browser with the node, once — and to the devices whose tunnel
//!         sessions reach the node by its key: at the address its account gave the machine, or on the relay given
//!     octoii pair [--home <dir>] [--port <port>] [--label <label>]
//!         A link that pairs a browser with the node, once, within five minutes — and, where the machine has an address,
//!         one for another device, drawn as a QR code on a terminal
//!     octoii open [--home <dir>] [--port <port>] [--label <label>]
//!         The web app opened in the person's browser, paired by a link made for it
//!     octoii issue [--home <dir>] [--label <label>]
//!         A session for a program of the person's: its bearer token, printed once
//!     octoii login [--home <dir>] [--accounts <url>] [--name <name>]
//!         This machine added to its person's account, by a code they confirm in their browser, and given its address,
//!         where the account's relay serves its home
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const providers = @import("providers.zig");
const Credentials = @import("credentials.zig");
const Node = @import("Node.zig");
const Home = @import("Home.zig");
const App = @import("App.zig");
const Access = @import("Access.zig");
const auth = @import("auth.zig");
const serve = @import("serve.zig");
const login = @import("login.zig");
const qr = @import("qr.zig");
const Station = @import("tunnel").Station;

/// What each of the node's commands runs with: the allocator Siphon's state lives on, the io, the login environment,
/// and memory that lasts the command.
const Process = struct {
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    arena: Allocator,
};

/// A debug build runs on the safe allocator, and fails as it ends where anything leaked; a release build runs on libc's,
/// as a server that runs for months must: it reuses what is freed, which the safe allocator never does.
pub fn main(minimal: std.process.Init.Minimal) u8 {
    ignoreBrokenPipes();
    var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    const gpa = if (builtin.mode == .debug) safe.allocator() else std.heap.c_allocator;
    const status = run(gpa, minimal);
    if (builtin.mode == .debug and safe.deinit() != 0) return 1;
    return status;
}

/// A pipe or a socket whose reader is gone ends the write to it, never the node — as a server that writes to pipes and
/// sockets has it: a coprocess that stopped reading, a client that went away.
fn ignoreBrokenPipes() void {
    if (builtin.target.os.tag == .windows) return;
    const ignore: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.PIPE, &ignore, null);
}

/// Runs the command `minimal`'s arguments name, on `gpa`; the status the program ends with.
fn run(gpa: Allocator, minimal: std.process.Init.Minimal) u8 {
    var threaded: std.Io.Threaded = .init(gpa, .{ .argv0 = .init(minimal.args), .environ = minimal.environ });
    defer threaded.deinit();
    var arena_allocator: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_allocator.deinit();
    var environ = std.process.Environ.createMap(minimal.environ, gpa) catch |err| return failed(err);
    defer environ.deinit();
    const process: Process = .{ .gpa = gpa, .io = threaded.io(), .environ = &environ, .arena = arena_allocator.allocator() };
    var args = std.process.Args.Iterator.initAllocator(minimal.args, process.arena) catch |err| return failed(err);
    defer args.deinit();
    _ = args.skip();
    return command(process, &args) catch |err| failed(err);
}

/// Runs the command `args` name; the status the program ends with where it ran to its end.
fn command(process: Process, args: *std.process.Args.Iterator) !u8 {
    const named = args.next() orelse return usage();
    const options = try optionsOf(args);
    if (std.mem.eql(u8, named, "serve")) {
        if (options.label != null) return usage();
        try serveClients(process, options);
        return 0;
    }
    if (options.app != null or options.catalogue != null or options.relay != null) return usage();
    if (std.mem.eql(u8, named, "login")) {
        if (options.label != null) return usage();
        return logIn(process, options);
    }
    if (options.accounts != null or options.name != null) return usage();
    if (std.mem.eql(u8, named, "pair")) {
        try pairClient(process, options);
    } else if (std.mem.eql(u8, named, "open")) {
        try openApp(process, options);
    } else if (std.mem.eql(u8, named, "issue")) {
        try issueSession(process, options);
    } else return usage();
    return 0;
}

/// The status of a command that failed with `err`, which is told: 2 for a command given wrong, as Unix commands end
/// for their usage, else 1.
fn failed(err: anyerror) u8 {
    if (err == error.Usage) return 2;
    std.debug.print("octoii: {s}\n", .{@errorName(err)});
    return 1;
}

fn usage() error{Usage} {
    std.debug.print(
        \\usage: octoii serve [--home <dir>] [--port <port>] [--app <dir>] [--catalogue <url>] [--relay <url>]
        \\       octoii pair [--home <dir>] [--port <port>] [--label <label>]
        \\       octoii open [--home <dir>] [--port <port>] [--label <label>]
        \\       octoii issue [--home <dir>] [--label <label>]
        \\       octoii login [--home <dir>] [--accounts <url>] [--name <name>]
        \\
    , .{});
    return error.Usage;
}

/// What a command is given: the Home, else `.octoii` in the person's home folder; the port clients reach the node at;
/// the folder of the web app's files; where a newer catalogue of models is served; the relay devices reach the node
/// through, a `ws` or `wss` address, in place of the one at the machine's address; what a link or a session made is
/// labelled; the accounts service a machine joins an
/// account at, and the name it joins by.
const Options = struct {
    home: ?[]const u8 = null,
    port: u16 = serve.default_port,
    app: ?[]const u8 = null,
    catalogue: ?[]const u8 = null,
    relay: ?[]const u8 = null,
    label: ?[]const u8 = null,
    accounts: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

fn optionsOf(args: *std.process.Args.Iterator) !Options {
    var options: Options = .{};
    while (args.next()) |arg| {
        const value = args.next() orelse return usage();
        if (std.mem.eql(u8, arg, "--home")) {
            options.home = value;
        } else if (std.mem.eql(u8, arg, "--port")) {
            options.port = std.fmt.parseInt(u16, value, 10) catch return usage();
        } else if (std.mem.eql(u8, arg, "--app")) {
            options.app = value;
        } else if (std.mem.eql(u8, arg, "--catalogue")) {
            options.catalogue = value;
        } else if (std.mem.eql(u8, arg, "--relay")) {
            options.relay = value;
        } else if (std.mem.eql(u8, arg, "--accounts")) {
            options.accounts = value;
        } else if (std.mem.eql(u8, arg, "--name")) {
            options.name = value;
        } else if (std.mem.eql(u8, arg, "--label")) {
            options.label = value;
        } else return usage();
    }
    return options;
}

/// Serves clients till the node is ended: Siphon's loop started, and the protocol — with the web app's files, where
/// they are given, and a link printed that pairs a browser, once — served on the loopback address, and in the tunnel
/// sessions of devices that reach the node at the address its account gave the machine, or through the relay given,
/// the node's station in its home there.
fn serveClients(process: Process, options: Options) !void {
    const io = process.io;
    const app: ?App = if (options.app) |folder| try App.open(io, process.arena, folder) else null;
    const node = try Node.open(process.gpa, io, process.environ, process.arena, options.home, .{ .port = options.port, .catalogue = options.catalogue });
    defer node.close();
    try node.siphon.runtime.start();
    // The providers' models listed, and the catalogue fetched, off the loop: the node serves at once.
    node.siphon.refreshModels();
    const server: serve.Server = .{ .siphon = node.siphon, .gpa = process.gpa, .access = node.access, .app = app, .cookie = try auth.cookieName(process.arena, options.port) };
    std.debug.print("octoii serves ws://127.0.0.1:{d}{s}; `octoii issue` gives a program a session\n", .{ options.port, serve.socket_path });
    if (app != null) {
        const link = try node.access.makeLink(process.arena, null, Access.all_scopes);
        const address = try pairingAddress(process.arena, options.port, link.credential);
        std.debug.print("octoii serves its web app at http://127.0.0.1:{d}; pair a browser with\n  {s}\nonce, within five minutes; `octoii pair` makes another\n", .{ options.port, address });
    }
    const station: ?*Station = if (try reachOf(process, node.home, options)) |reach| try joinRelay(process, node, reach) else null;
    defer if (station) |joined| joined.deinit();
    // Serving ends as the node is asked to end, or as it fails: whichever comes first, the others are cancelled — the
    // clients let go, then Siphon's loop stopped and it closed, its requests waiting on, interrupted as the node starts
    // again.
    var buffer: [3]Ended = undefined;
    var ending: std.Io.Select(Ended) = .init(io, &buffer);
    try ending.concurrent(.served, serve.serve, .{ &server, options.port });
    if (station) |joined| try ending.concurrent(.tunneled, serve.serveTunnel, .{ &server, joined });
    try ending.concurrent(.asked, waitForEnd, .{io});
    const first = try ending.await();
    ending.cancelDiscard();
    switch (first) {
        .served => |served| try served,
        .tunneled => |tunneled| try tunneled,
        .asked => |asked| try asked,
    }
}

/// Where devices reach the node: the relay its station joins, and the machine's address, where its account gave it one.
const Reach = struct { relay: []const u8, address: ?[]const u8 };

/// Where devices reach the node: through the relay the options name; else at the address its account gave the machine,
/// whose relay is at its host; null where the machine has neither, the node reached on the loopback alone.
fn reachOf(process: Process, home: Home, options: Options) !?Reach {
    if (options.relay) |relay| return .{ .relay = relay, .address = null };
    const address = try addressOf(process, home) orelse return null;
    return .{ .relay = try login.relayAt(process.arena, address), .address = address };
}

/// The address the machine's account gave it; null where it has none.
fn addressOf(process: Process, home: Home) !?[]const u8 {
    const kept = std.Io.Dir.cwd().readFileAlloc(process.io, home.address, process.arena, .limited(512)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return std.mem.trim(u8, kept, " \t\r\n");
}

/// The node's station, in its home on the relay `reach` names: the home of its own key, where devices reach it by that
/// key.
fn joinRelay(process: Process, node: *Node, reach: Reach) !*Station {
    const station = try Station.init(process.gpa, process.io, node.identity, .{});
    errdefer station.deinit();
    const key = node.identity.publicKey();
    _ = try station.join(reach.relay, key);
    if (reach.address) |address| {
        std.debug.print("octoii is reached at {s}\n", .{address});
    } else {
        std.debug.print("octoii is reached as {f} through {s}\n", .{ key, reach.relay });
    }
    return station;
}

/// The address that pairs a browser with the node at `port` by `credential`: the app's pairing page, the credential in
/// the address's fragment, which a browser never sends to any server.
fn pairingAddress(arena: Allocator, port: u16, credential: []const u8) ![]const u8 {
    return arena.print("http://127.0.0.1:{d}/pair#token={s}", .{ port, credential });
}

/// Where a device opens Octoii that is not on the machine: the web app, which reaches the machine through its relay.
const app_origin = "https://app.octoii.com";

/// The address that pairs a device with the machine of `key`, reached through `relay`, by `credential`: the web app's
/// pairing page, what it needs in the address's fragment, which a browser never sends to any server.
fn remotePairingAddress(arena: Allocator, relay: []const u8, key: anytype, credential: []const u8) ![:0]const u8 {
    return arena.printSentinel(app_origin ++ "/pair#relay={s}&key={f}&token={s}", .{ relay, key, credential }, 0);
}

/// The access kept in the Home `options` names, as the person's commands reach it beside a node that may be running.
fn accessOf(process: Process, options: Options) !Access {
    const home = try Home.open(process.io, process.environ, process.arena, options.home);
    return Access.open(process.io, process.arena, home.access);
}

/// Prints the addresses of a link that pairs a browser with the node, once, while it lasts: on this computer, and, where
/// the machine has an address, on any other device.
fn pairClient(process: Process, options: Options) !void {
    const home = try Home.open(process.io, process.environ, process.arena, options.home);
    const access = try Access.open(process.io, process.arena, home.access);
    const link = try access.makeLink(process.arena, options.label, Access.all_scopes);
    const local = try pairingAddress(process.arena, options.port, link.credential);
    const address = try addressOf(process, home) orelse return printLine(process.io, local);
    const identity = try Node.identityOf(process.io, process.arena, home.identity);
    const remote = try remotePairingAddress(process.arena, try login.relayAt(process.arena, address), identity.publicKey(), link.credential);
    try printPairing(process.io, local, remote);
}

/// Prints both addresses of a link, and, on a terminal, the other device's as a code its camera reads.
fn printPairing(io: std.Io, local: []const u8, remote: [:0]const u8) !void {
    var buffer: [512]u8 = undefined;
    const stdout = std.Io.File.stdout();
    var writer = stdout.writerStreaming(io, &buffer);
    const out = &writer.interface;
    try out.print("on this computer:  {s}\non another device: {s}\n", .{ local, remote });
    if (try stdout.isTty(io)) {
        try out.writeByte('\n');
        try qr.draw(out, remote);
        try out.writeByte('\n');
    }
    try out.writeAll("either one, once, within five minutes\n");
    try out.flush();
}

/// Opens the node's web app in the person's browser at the address of a link made for it, which pairs the browser
/// once: the link lasts minutes and is spent as it pairs, so the address is no credential once used.
fn openApp(process: Process, options: Options) !void {
    const link = try (try accessOf(process, options)).makeLink(process.arena, options.label, Access.all_scopes);
    const address = try pairingAddress(process.arena, options.port, link.credential);
    const opener = switch (builtin.target.os.tag) {
        .macos => [_][]const u8{ "open", address },
        .windows => [_][]const u8{ "cmd.exe", "/c", "start", "", address },
        else => [_][]const u8{ "xdg-open", address },
    };
    var child = try std.process.spawn(process.io, .{ .argv = &opener });
    if (!(try child.wait(process.io)).success()) return error.BrowserNotOpened;
}

/// Prints the bearer token of a session issued for a program of the person's, once: the program sends it as it
/// connects, in its `Authorization` header.
fn issueSession(process: Process, options: Options) !void {
    const made = try (try accessOf(process, options)).issue(process.arena, .bearer, options.label, Access.all_scopes);
    try printLine(process.io, made.credential);
}

/// Adds this machine to its person's account at the accounts service the options name — Octoii's, where they name none —
/// by its identity and its name, the machine's own where none is given: the code to confirm printed, then what came of
/// it, the address it was given kept in its Home; 0 where the machine was added.
fn logIn(process: Process, options: Options) !u8 {
    const home = try Home.open(process.io, process.environ, process.arena, options.home);
    const identity = try Node.identityOf(process.io, process.arena, home.identity);
    const name = options.name orelse try Home.machineNameOf(process.arena, process.environ) orelse "octoii";
    var client: std.http.Client = .{ .allocator = process.gpa, .io = process.io };
    defer client.deinit();
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(process.io, &buffer);
    const out = &writer.interface;
    const outcome = try login.login(&client, process.arena, options.accounts orelse login.default_accounts, identity, name, out);
    switch (outcome) {
        .added => |address| {
            try std.Io.Dir.cwd().writeFile(process.io, .{ .sub_path = home.address, .data = try std.mem.concat(process.arena, u8, &.{ address, "\n" }) });
            try out.print("{s} is on your account now, reached at {s}\n", .{ name, address });
        },
        .denied => |why| try out.print("not added: {s}\n", .{why orelse "cancelled in the browser"}),
        .refused => |why| try out.print("not added: {s}\n", .{why orelse "the accounts refused the machine's proof"}),
        .expired => try out.print("not added: the code was not confirmed in time; run octoii login again\n", .{}),
    }
    try out.flush();
    return if (outcome == .added) 0 else 1;
}

/// Prints `line` on the standard output.
fn printLine(io: std.Io, line: []const u8) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    try writer.interface.print("{s}\n", .{line});
    try writer.interface.flush();
}

/// How serving ended: the server on the loopback or in the tunnel failed, or the node was asked to end.
const Ended = union(enum) {
    served: @typeInfo(@TypeOf(serve.serve)).@"fn".return_type.?,
    tunneled: @typeInfo(@TypeOf(serve.serveTunnel)).@"fn".return_type.?,
    asked: @typeInfo(@TypeOf(waitForEnd)).@"fn".return_type.?,
};

/// The pipe a signal to end writes to, from its handler, as the self-pipe trick has it: a write is all a handler may
/// do safely.
var end_pipe: [2]std.c.fd_t = .{ -1, -1 };

fn onEnd(_: std.posix.SIG) callconv(.c) void {
    _ = std.c.write(end_pipe[1], "e", 1);
}

/// Waits until the node is asked to end: SIGTERM, as a service manager asks, or SIGINT, from the terminal.
fn waitForEnd(io: std.Io) !void {
    if (std.c.pipe(&end_pipe) != 0) return error.NoPipe;
    defer for (end_pipe) |fd| {
        _ = std.c.close(fd);
    };
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = onEnd }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.TERM, &action, null);
    std.posix.sigaction(.INT, &action, null);
    const pipe: std.Io.File = .{ .handle = end_pipe[0], .flags = .{ .nonblocking = false } };
    var byte: [1]u8 = undefined;
    _ = try pipe.readStreaming(io, &.{&byte});
}

test {
    _ = providers;
    _ = serve;
    _ = @import("Request.zig");
    _ = @import("tunnel_test.zig");
    _ = login;
    _ = qr;
    _ = App;
    _ = Access;
    _ = auth;
    _ = Credentials;
    _ = Node;
    _ = Home;
    _ = @import("catalogue.zig");
    _ = @import("files.zig");
}
