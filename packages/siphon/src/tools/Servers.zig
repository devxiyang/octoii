//! The MCP servers whose tools a thread's scripts call, as configurations name them in the common `mcpServers` shape:
//! the person's own, in the Home's `mcp.json`; then its project's, in the `.mcp.json` of the project's folder, once the
//! person trusts them, as a project's code runs — one of a name the person's has standing for theirs, as the nearer
//! setting holds. Each is a command the machine runs, in its configuration's folder unless it names its own, talked to
//! over its standard input and output, its `env` set over the machine's own, or, where `inheritEnv` is false, all it
//! has; connected as its tools are first asked for, then kept and shared by every thread, in the servers' pool, and
//! stopped once no thread used it for a while, to be started again as one next does. A tool of one is named
//! `<server>.<tool>`, as a mount table names what is under a mount point: a call of one goes to its server; and the
//! model is told the tools of them all as a catalog, called from `execute`. A server whose configuration changed is
//! connected anew, and one its configuration no longer names, or names untrusted, is stopped once nothing uses it. A
//! client is shown the servers a thread working in a folder would use, each as it stands, and the project's
//! configuration with what the person decided on it, nothing started for the showing.
const Servers = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const mcp = @import("mcp");
const runtime_ = @import("../runtime.zig");
const Runtime = runtime_.Runtime;
const threads = @import("../threads.zig");
const log = threads.log;
const Tool = @import("Tool.zig");
const Coprocess = @import("Coprocess.zig");
const declarations = @import("declarations.zig");
const Machine = @import("../machine.zig");
const trust = @import("trust.zig");

allocator: Allocator,
runtime: *Runtime,
/// What the tools are given by the host: the machine the servers run on, and the file of the person's own.
host: Tool.Host,
/// The clients of the servers, connected as first needed and shared by the tasks that call them: the pool keeps its own
/// lock, as `ai` keeps its, so what the runtime's loop keeps stays its alone.
pool: mcp.Pool,

pub fn init(runtime: *Runtime, host: Tool.Host) Servers {
    return .{ .allocator = runtime.allocator, .runtime = runtime, .host = host, .pool = .init(runtime.allocator, .{ .host = .{ .io = runtime.host.io }, .client = .{ .name = "octoii", .version = "0.0.1" } }, idle_ms) };
}

/// How long a server no thread uses keeps running before it is stopped.
const idle_ms = 10 * std.time.ms_per_min;

/// Closes each server's client, its server ended: no task holds one now.
pub fn deinit(servers: *Servers) void {
    servers.pool.deinit();
}

/// A server as a configuration names it: run as a command with its arguments, its variables set over the machine's
/// own, in its folder; the configuration it comes from, by its path; and the key the pool knows it by, which any change
/// of these changes.
pub const Server = struct {
    name: []const u8,
    command: []const u8,
    args: []const []const u8 = &.{},
    variables: []const [2][]const u8 = &.{},
    /// Whether it starts with the machine's own variables under its own; else with its own alone.
    inherit: bool = true,
    cwd: []const u8,
    source: []const u8,
    key: []const u8 = "",
};

/// The servers a thread may use, what of their configurations could not be taken, each said for the model to read,
/// and the configurations read, by their paths — one whose servers are not run among them; and its project's
/// configuration, where it names servers, with what the person decided on it.
pub const Configured = struct {
    servers: []const Server = &.{},
    problems: []const []const u8 = &.{},
    sources: []const []const u8 = &.{},
    project: ?Project = null,

    /// What the person is asked to trust: the project's configuration, where they decided nothing on it as it is.
    pub fn asked(configured_: Configured) ?trust.Asked {
        const project = configured_.project orelse return null;
        return if (project.trusted == null) project.named else null;
    }
};

/// A project's configuration of servers, as the person decides on it: what it names, and whether they trust it — none
/// where they decided nothing on it as it is.
pub const Project = struct { named: trust.Asked, trusted: ?bool };

/// Where a thread works, as the servers it may use are found from: its workspace, and the project folder that holds it.
pub const Place = struct { workspace: ?[]const u8 = null, project: ?[]const u8 = null };

/// The name of a project's configuration, in its folder.
const project_name = ".mcp.json";

/// The servers the thread `tid` may use, as its manifest says where it works.
pub fn configured(servers: *Servers, arena: Allocator, tid: []const u8) !Configured {
    const manifest = try threads.manifestOf(servers.runtime.volume, &arena, try threads.pathOf(arena, tid));
    return servers.configuredAt(arena, .{ .workspace = manifest.workspace, .project = manifest.project });
}

/// The servers a thread working at `place` may use: the person's, as the Home's `mcp.json` names them; then those its
/// project's `.mcp.json` names, in the project's folder, where the person trusts them — each standing for one of its
/// name the person's names.
pub fn configuredAt(servers: *Servers, arena: Allocator, place: Place) !Configured {
    var found: Gathered = .{ .arena = arena };
    const home = servers.host.machine.home;
    const machine = Machine.open(servers.host.machine, .{ .base = .{ .workspace = place.workspace orelse Machine.root, .home = home } }) catch |err| switch (err) {
        error.NoMachine => {
            if (servers.host.mcp) |path| try found.sources.append(arena, path);
            return found.done();
        },
        else => return err,
    };
    defer machine.close();
    if (servers.host.mcp) |path| {
        try found.sources.append(arena, path);
        if (try machine.readAll(&arena, path, configuration_bytes_max)) |text| try found.add(try parsed(arena, path, text, home orelse Machine.root));
    }
    if (place.workspace == null) return found.done();
    try found.addProject(servers.runtime, machine, place.project orelse return found.done());
    return found.done();
}

/// The servers of the configurations read so far, in a thread's arena.
const Gathered = struct {
    arena: Allocator,
    servers: std.ArrayList(Server) = .empty,
    problems: std.ArrayList([]const u8) = .empty,
    sources: std.ArrayList([]const u8) = .empty,
    project: ?Project = null,

    /// The servers and problems of `configuration`, a server standing for one of its name read before.
    fn add(gathered: *Gathered, configuration: Configured) !void {
        try gathered.problems.appendSlice(gathered.arena, configuration.problems);
        for (configuration.servers) |server| {
            for (gathered.servers.items) |*before| {
                if (std.mem.eql(u8, before.name, server.name)) {
                    before.* = server;
                    break;
                }
            } else try gathered.servers.append(gathered.arena, server);
        }
    }

    /// The servers of the project the machine's workspace is in, where the person trusts them; where they decided
    /// nothing on its configuration as it is, it is asked of them.
    fn addProject(gathered: *Gathered, runtime: *Runtime, machine: Machine, folder: []const u8) !void {
        const arena = gathered.arena;
        const path = try std.fs.path.join(arena, &.{ folder, project_name });
        try gathered.sources.append(arena, path);
        const text = machine.readAll(&arena, path, configuration_bytes_max) catch |err| switch (err) {
            error.Refused => return gathered.problems.append(arena, try arena.print("{s} could not be read", .{path})),
            else => return err,
        } orelse return;
        const configuration = try parsed(arena, path, text, folder);
        if (configuration.servers.len == 0) return gathered.add(configuration);
        const digest = trust.digestOf(text);
        const named: trust.Asked = .{ .folder = folder, .path = path, .digest = try arena.dupe(u8, &digest), .servers = try shownOf(arena, configuration.servers) };
        const trusted = try trust.decided(runtime.volume, &arena, folder, &digest);
        gathered.project = .{ .named = named, .trusted = trusted };
        if (trusted orelse false) try gathered.add(configuration);
    }

    fn done(gathered: *Gathered) Configured {
        return .{ .servers = gathered.servers.items, .problems = gathered.problems.items, .sources = gathered.sources.items, .project = gathered.project };
    }
};

/// `servers` as the person is shown them, asked to trust them.
fn shownOf(arena: Allocator, servers: []const Server) ![]const trust.Shown {
    const out = try arena.alloc(trust.Shown, servers.len);
    for (servers, out) |server, *each| each.* = .{ .name = server.name, .command = server.command, .args = server.args };
    return out;
}

/// The configuration `text`, of the file at `path`, whose servers run in `folder` where they name no folder of their
/// own, or one relative to it: each server under `mcpServers` run as a command; each that cannot be one a problem,
/// saying why, as is a file that holds no configuration.
pub fn parsed(arena: Allocator, path: []const u8, text: []const u8, folder: []const u8) !Configured {
    const root = std.json.parseFromSliceLeaky(Value, arena, text, .{}) catch return .{ .problems = try one(arena, "{s} is not JSON", .{path}) };
    const named = if (root == .object) root.object.get("mcpServers") else null;
    if (named == null) return .{};
    if (named.? != .object) return .{ .problems = try one(arena, "{s}: mcpServers is not an object", .{path}) };
    var servers: std.ArrayList(Server) = .empty;
    var problems: std.ArrayList([]const u8) = .empty;
    for (named.?.object.keys(), named.?.object.values()) |name, entry| {
        switch (try serverOf(arena, .{ .name = name, .command = "", .cwd = folder, .source = path }, entry)) {
            .server => |server| try servers.append(arena, server),
            .why => |why| try problems.append(arena, try arena.print("{s}: the server {s} is not run: {s}", .{ path, name, why })),
        }
    }
    return .{ .servers = servers.items, .problems = problems.items };
}

fn one(arena: Allocator, comptime format: []const u8, arguments: anytype) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{try arena.print(format, arguments)});
}

/// The server the configuration's `entry` describes, as `named` names it, from its source, run in its folder unless
/// it names its own; else why it cannot be run.
fn serverOf(arena: Allocator, named: Server, entry: Value) Allocator.Error!union(enum) { server: Server, why: []const u8 } {
    // Its tools are named after it, a dot between: a dot of its own would part them elsewhere.
    if (named.name.len == 0 or std.mem.indexOfScalar(u8, named.name, '.') != null) return .{ .why = "its name is empty or holds a dot, which parts a server's name from its tools'" };
    if (entry != .object) return .{ .why = "it is not an object" };
    const object = entry.object;
    const command = object.get("command") orelse return .{ .why = if (object.get("url") != null) "a server reached by its URL is not taken yet, only one run as a command" else "it has no command" };
    if (command != .string or command.string.len == 0) return .{ .why = "its command is not a string" };
    var server = named;
    server.command = command.string;
    if (object.get("args")) |args| {
        if (args != .array) return .{ .why = "its args are not an array" };
        const taken = try arena.alloc([]const u8, args.array.items.len);
        for (args.array.items, taken) |arg, *each| {
            if (arg != .string) return .{ .why = "an argument of its is not a string" };
            each.* = arg.string;
        }
        server.args = taken;
    }
    if (object.get("env")) |env| {
        if (env != .object) return .{ .why = "its env is not an object" };
        const taken = try arena.alloc([2][]const u8, env.object.count());
        for (env.object.keys(), env.object.values(), taken) |key, value, *each| {
            if (value != .string) return .{ .why = "a variable of its env is not a string" };
            each.* = .{ key, value.string };
        }
        server.variables = taken;
    }
    if (object.get("inheritEnv")) |inherit| {
        if (inherit != .bool) return .{ .why = "its inheritEnv is not true or false" };
        server.inherit = inherit.bool;
    }
    if (object.get("cwd")) |cwd| {
        if (cwd != .string) return .{ .why = "its cwd is not a string" };
        server.cwd = try std.fs.path.resolve(arena, &.{ named.cwd, cwd.string });
    }
    server.key = try keyOf(arena, server);
    return .{ .server = server };
}

/// The key of `server` in the pool: its source's prefix, then its name and a digest of all it is run with.
fn keyOf(arena: Allocator, server: Server) Allocator.Error![]const u8 {
    var hasher: std.hash.Wyhash = .init(0);
    for ([_][]const u8{ server.command, server.cwd, if (server.inherit) "inherit" else "alone" }) |part| {
        hasher.update(part);
        hasher.update("\x00");
    }
    for (server.args) |arg| {
        hasher.update(arg);
        hasher.update("\x00");
    }
    for (server.variables) |pair| {
        hasher.update(pair[0]);
        hasher.update("=");
        hasher.update(pair[1]);
        hasher.update("\x00");
    }
    return arena.print("{s}{s}#{x:0>16}", .{ try prefixOf(arena, server.source), server.name, hasher.final() });
}

/// What the keys of the servers the configuration at `source` names begin with, which no other's do: its path, and a
/// byte no path holds.
fn prefixOf(arena: Allocator, source: []const u8) Allocator.Error![]const u8 {
    return std.mem.concat(arena, u8, &.{ source, "\x00" });
}

/// The most of a configuration read.
const configuration_bytes_max = 1 << 20;

/// What makes a server's transport, as the pool asks for one: the server run on the machine, talked to over stdio.
const Making = struct {
    servers: *Servers,
    server: Server,

    fn make(context: *anyopaque, slot: *mcp.failure.Slot) mcp.failure.Error!mcp.Transport {
        const making: *const Making = @ptrCast(@alignCast(context));
        const servers = making.servers;
        const server = making.server;
        const machine = servers.host.machine.handle orelse return slot.fail(.{ .connection_lost = "there is no machine to run the MCP server on" });
        const argv = try slot.arena.alloc([]const u8, server.args.len + 1);
        argv[0] = server.command;
        @memcpy(argv[1..], server.args);
        const coprocess = switch (try Coprocess.start(servers.allocator, slot.arena, .{
            .io = servers.pool.options.host.io,
            .machine = machine,
            .argv = argv,
            .cwd = server.cwd,
            .variables = server.variables,
            .inherit = server.inherit,
            .name = try slot.arena.print("the MCP server {s}", .{server.name}),
        })) {
            .coprocess => |started| started,
            .failed => |why| return slot.fail(.{ .connection_lost = why }),
        };
        const stdio = try mcp.stdio.Stdio.start(servers.allocator, &servers.pool.options.host, slot, coprocess.process());
        return stdio.transport();
    }
};

/// The client of `server`, connected now where it is not; or why it could not be, in `arena`.
fn lease(servers: *Servers, arena: Allocator, server: Server) !mcp.failure.Outcome(mcp.Pool.Lease) {
    var making: Making = .{ .servers = servers, .server = server };
    return servers.pool.lease(arena, server.key, .{ .context = &making, .make = Making.make });
}

/// A server as it stands now: the tools it has, or why they could not be had.
const Standing = struct { server: Server, tools: []const mcp.types.Tool = &.{}, failure: ?[]const u8 = null };

/// Each server `found` names as it stands, its tools listed: those its configurations named before and no longer run
/// let go of.
fn standing(servers: *Servers, arena: Allocator, found: Configured) ![]const Standing {
    for (found.sources) |source| {
        var keys: std.ArrayList([]const u8) = .empty;
        for (found.servers) |server| if (std.mem.eql(u8, server.source, source)) try keys.append(arena, server.key);
        servers.pool.retain(try prefixOf(arena, source), keys.items);
    }
    const out = try arena.alloc(Standing, found.servers.len);
    for (found.servers, out) |server, *each| {
        each.* = .{ .server = server };
        const leased = switch (try servers.lease(arena, server)) {
            .done => |leased| leased,
            .failed => |failure| {
                each.failure = try failure.message(arena);
                continue;
            },
        };
        defer leased.release();
        switch (try leased.client().allTools(arena, .{})) {
            .done => |listed| each.tools = listed,
            .failed => |failure| each.failure = try failure.message(arena),
        }
    }
    return out;
}

/// What the model of the thread `tid` is told of the servers' tools: the catalog, the section of what it is told that
/// holds them, none where no configuration names a server; and what the person is asked to trust, where they are.
pub const Catalog = struct { text: ?[]const u8 = null, asked: ?trust.Asked = null };

pub fn catalog(servers: *Servers, arena: Allocator, tid: []const u8) !Catalog {
    const found = try servers.configured(arena, tid);
    const stood = try servers.standing(arena, found);
    const problems = try toldProblems(arena, found);
    if (found.servers.len == 0 and problems.len == 0) return .{ .asked = found.asked() };
    return .{ .text = try catalogOf(arena, problems, stood), .asked = found.asked() };
}

/// What the model is told could not be taken of the configurations: their problems, and a project's servers not run as
/// the person did not trust them, or has not decided yet.
fn toldProblems(arena: Allocator, found: Configured) ![]const []const u8 {
    const project = found.project orelse return found.problems;
    const note = if (project.trusted) |trusted|
        if (trusted) return found.problems else ": its servers are not run: the person did not trust them"
    else
        ": its servers are not run till the person trusts them; they are asked";
    return std.mem.concat(arena, []const u8, &.{ found.problems, &.{try std.mem.concat(arena, u8, &.{ project.named.path, note })} });
}

fn catalogOf(arena: Allocator, problems: []const []const u8, servers: []const Standing) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    try writer.writeAll("<catalog>\n" ++ catalog_intro ++ "\n");
    for (problems) |problem| try writer.print("\n// {s}\n", .{problem});
    for (servers) |each| {
        try writer.print("\n// The server {s}", .{each.server.name});
        if (each.failure) |why| {
            try writer.print(", which cannot be reached: {s}\n", .{why});
            continue;
        }
        try writer.writeAll(":\n");
        for (each.tools) |tool| try declarations.declare(writer, try std.mem.concat(arena, u8, &.{ each.server.name, ".", tool.name }), tool.description, tool.inputSchema);
    }
    try writer.writeAll("</catalog>");
    return out.written();
}

/// A server as a client is shown it: its name, the configuration it comes from, by its path, the command it is run as,
/// whether it is connected now, and the names of its tools where it is.
pub const Shown = struct {
    name: []const u8,
    source: []const u8,
    command: []const u8,
    args: []const []const u8,
    connected: bool,
    tools: []const []const u8 = &.{},
};

/// What a client is shown of the servers a thread working at a place would use: those that run, each as it stands; what
/// of their configurations could not be taken; the person's own configuration, by its path, where the host names one;
/// and the project's configuration, with what the person decided on it.
pub const Listed = struct { servers: []const Shown, problems: []const []const u8, person: ?[]const u8, project: ?Project };

/// The servers a thread working at `place` would use, as `Listed` shows them, nothing started for the showing: a server
/// not connected is told as not, its tools unknown till a thread first needs them.
pub fn list(servers: *Servers, arena: Allocator, place: Place) !Listed {
    const found = try servers.configuredAt(arena, place);
    const shown = try arena.alloc(Shown, found.servers.len);
    for (found.servers, shown) |server, *each| {
        each.* = .{ .name = server.name, .source = server.source, .command = server.command, .args = server.args, .connected = false };
        const leased = servers.pool.leaseStanding(server.key) orelse continue;
        defer leased.release();
        each.connected = true;
        switch (try leased.client().allTools(arena, .{})) {
            .done => |tools| {
                const names = try arena.alloc([]const u8, tools.len);
                for (tools, names) |tool, *name| name.* = tool.name;
                each.tools = names;
            },
            .failed => {},
        }
    }
    return .{ .servers = shown, .problems = found.problems, .person = servers.host.mcp, .project = found.project };
}

/// What the catalog begins with: how its tools are called.
const catalog_intro = "The tools of your MCP servers. A script run by execute calls each as an async function under `tools`, given its arguments as one object, as declared here: it gives the tool's text, and throws an Error where the tool fails.";

/// The names the tools of the servers the thread `tid` may use are called by from a script: `<server>.<tool>`, those
/// of every server that stands.
pub fn toolNames(servers: *Servers, arena: Allocator, tid: []const u8) ![]const []const u8 {
    const found = try servers.configured(arena, tid);
    var names: std.ArrayList([]const u8) = .empty;
    for (try servers.standing(arena, found)) |each| {
        for (each.tools) |tool| try names.append(arena, try std.mem.concat(arena, u8, &.{ each.server.name, ".", tool.name }));
    }
    return names.items;
}

/// The call `asked` names — `<server>.<tool>` — as its server answers it, under the request `key`: what the tool gave,
/// as every tool's is told; no tool, where no server its thread may use has that name.
pub fn call(servers: *Servers, arena: Allocator, key: []const u8, asked: Tool.Call) !log.CallOutcome {
    const dot = std.mem.indexOfScalar(u8, asked.name, '.') orelse return unavailable(arena, asked.name);
    const found = try servers.configured(arena, asked.thread);
    const server = for (found.servers) |server| {
        if (std.mem.eql(u8, server.name, asked.name[0..dot])) break server;
    } else return unavailable(arena, asked.name);
    const arguments = std.json.parseFromSliceLeaky(Value, arena, asked.arguments, .{}) catch return invalid(arena, "The arguments are not JSON.");
    if (arguments != .object) return invalid(arena, "The arguments are not a JSON object.");
    const leased = switch (try servers.lease(arena, server)) {
        .done => |leased| leased,
        .failed => |failure| return Tool.outcomeOf(&servers.host, arena, key, .{ .outcome = .refused, .text = try failure.message(arena) }),
    };
    defer leased.release();
    const result = switch (try leased.client().callTool(arena, asked.name[dot + 1 ..], arguments, .{})) {
        .done => |result| result,
        .failed => |failure| switch (failure) {
            // Cut off by a stop: its request is answered as cut off.
            .canceled => return error.Canceled,
            else => return Tool.outcomeOf(&servers.host, arena, key, .{ .outcome = .refused, .text = try failure.message(arena) }),
        },
    };
    return Tool.outcomeOf(&servers.host, arena, key, try outputOf(arena, result));
}

fn unavailable(arena: Allocator, name: []const u8) !log.CallOutcome {
    return Tool.noted(arena, .unavailable, try arena.print("no tool named {s}", .{name}));
}

fn invalid(arena: Allocator, why: []const u8) !log.CallOutcome {
    return .{ .status = .@"invalid-arguments", .output = try arena.dupe(u8, why) };
}

/// What a server's tool gave, as every tool's is told: its text, each block on a line of its own, and of what is no
/// text a note of what it is; its structured content where it gave no text; refused where it says it failed.
fn outputOf(arena: Allocator, result: mcp.types.CallToolResult) !Tool.Output {
    var text: std.Io.Writer.Allocating = .init(arena);
    var notes: Tool.Notes = .{ .arena = arena };
    for (result.content) |block| switch (block) {
        .text => |given| try lineOf(&text, given.text),
        .resource => |embedded| switch (embedded.resource) {
            .text => |given| try lineOf(&text, given.text),
            .blob => |given| try notes.add("a resource, {s}, of {d} bytes as base64, left out", .{ given.uri, given.blob.len }),
        },
        .image => |given| try notes.add("an image, {s}, of {d} bytes as base64, left out", .{ given.mimeType, given.data.len }),
        .audio => |given| try notes.add("audio, {s}, of {d} bytes as base64, left out", .{ given.mimeType, given.data.len }),
        .resource_link => |given| try notes.add("a resource: {s} ({s})", .{ given.uri, given.name }),
    };
    if (text.written().len == 0) if (result.structuredContent) |structured| try text.writer.print("{f}", .{std.json.fmt(structured, .{})});
    return .{ .outcome = if (result.isError orelse false) .refused else .done, .text = text.written(), .notes = notes.list.items };
}

fn lineOf(out: *std.Io.Writer.Allocating, text: []const u8) !void {
    if (out.written().len > 0) try out.writer.writeByte('\n');
    try out.writer.writeAll(text);
}

test "the configuration's servers are those run as commands, each that cannot be one a problem said why" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const found = try parsed(arena, "/home/me/.octoii/mcp.json",
        \\{"mcpServers":{
        \\  "docs":{"command":"docs-server","args":["--stdio"],"env":{"TOKEN":"t"},"cwd":"/work"},
        \\  "remote":{"url":"https://example.invalid/mcp"},
        \\  "a.b":{"command":"x"},
        \\  "near":{"command":"y","cwd":"tools"},
        \\  "here":{"command":"z"}
        \\}}
    , "/home/me");
    try std.testing.expectEqual(@as(usize, 3), found.servers.len);
    // A server runs in its configuration's folder, or in one its own names, from there.
    try std.testing.expectEqualStrings("/home/me/tools", found.servers[1].cwd);
    try std.testing.expectEqualStrings("/home/me", found.servers[2].cwd);
    const docs = found.servers[0];
    try std.testing.expectEqualStrings("docs-server", docs.command);
    try std.testing.expectEqualStrings("--stdio", docs.args[0]);
    try std.testing.expectEqualStrings("TOKEN", docs.variables[0][0]);
    try std.testing.expectEqualStrings("/work", docs.cwd);
    try std.testing.expectStringStartsWith(docs.key, "/home/me/.octoii/mcp.json\x00docs#");
    try std.testing.expectEqual(@as(usize, 2), found.problems.len);
    try std.testing.expectStringEndsWith(found.problems[0], "the server remote is not run: a server reached by its URL is not taken yet, only one run as a command");
    // A change of what it is run with is another server, connected anew.
    const changed = try parsed(arena, "/home/me/.octoii/mcp.json", "{\"mcpServers\":{\"docs\":{\"command\":\"docs-server\",\"args\":[\"--stdio\"],\"env\":{\"TOKEN\":\"u\"},\"cwd\":\"/work\"}}}", "/home/me");
    try std.testing.expect(!std.mem.eql(u8, docs.key, changed.servers[0].key));
    // One that starts with its own variables alone is told so, and is another server too.
    const alone = try parsed(arena, "/home/me/.octoii/mcp.json", "{\"mcpServers\":{\"docs\":{\"command\":\"docs-server\",\"args\":[\"--stdio\"],\"env\":{\"TOKEN\":\"t\"},\"cwd\":\"/work\",\"inheritEnv\":false}}}", "/home/me");
    try std.testing.expect(!alone.servers[0].inherit);
    try std.testing.expect(!std.mem.eql(u8, docs.key, alone.servers[0].key));
    // The same server named by another configuration is another server.
    const elsewhere = try parsed(arena, "/work/.mcp.json", "{\"mcpServers\":{\"docs\":{\"command\":\"docs-server\",\"args\":[\"--stdio\"],\"env\":{\"TOKEN\":\"t\"},\"cwd\":\"/work\"}}}", "/work");
    try std.testing.expect(!std.mem.eql(u8, docs.key, elsewhere.servers[0].key));
    try std.testing.expectEqual(@as(usize, 1), (try parsed(arena, "mcp.json", "not json", "/")).problems.len);
    try std.testing.expectEqual(@as(usize, 0), (try parsed(arena, "mcp.json", "{}", "/")).servers.len);
}
