//! Siphon, put together: its kernel, the runtime, on one volume of Beak's, and the parts on it — the tools a thread's
//! model may call, the models its turns ask, the programs and requests of the threads, and the clients that follow
//! them — opened on the platform the host gives, and closed together. Each part reaches the others it needs as it is
//! given them here; none reaches this.
const Siphon = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const ai = @import("ai");
const h = @import("beak.zig").h;
const runtime_ = @import("runtime.zig");
const Waits = runtime_.Waits;
const Runtime = runtime_.Runtime;
const Machine = @import("machine.zig");
const threads = @import("threads.zig");
const image = @import("image.zig");
const tools_ = @import("tools.zig");
const agent = @import("agent.zig");
const protocol = @import("protocol.zig");
const Terminals = @import("terminals.zig");
const Browser = @import("browser.zig");

allocator: Allocator,
runtime: *Runtime,
/// The models the threads' turns ask, through the host's network and secrets, their ids minted from the volume.
models: *ai.Models,
/// The tools a thread's model may call: Siphon's own, built in — the coding tools, scripts, questions to the person and,
/// where there is a browser, its pages — and the MCP servers'.
tools: tools_.Table,
/// Where what a thread's model is told comes from.
sources: agent.system.Sources,
/// The threads' terminals on the machine.
terminals: Terminals,
/// The browser the threads' pages are open in.
browser: Browser,
/// The clients of the protocol, which follow the threads and read the machine's files.
clients: protocol.Clients,
/// What the threads' turns ask and call.
turns: agent.turn.Turns,

pub const Device = Runtime.Device;

/// What the host gives as it opens Siphon: the platform, never state Siphon keeps — each part given what of it is its.
pub const Host = struct {
    io: std.Io,
    /// None: the io's real clock.
    clock: ?foundation.time.Clock = null,
    /// Where the volume is kept.
    device: Device = .memory,
    /// The network: none, the standard library's client on the io.
    http: ?foundation.http.Http = null,
    /// The providers' credentials, kept by the host with its secrets; none, none kept.
    credentials: ?ai.driver.Credentials = null,
    /// The host's sessions and the links that pair its clients, which its transport authenticates clients by; none,
    /// the host keeps none.
    access: ?protocol.Access = null,
    /// The address a provider's sign-in sends the browser back to: the host's own, on this machine's loopback, where its
    /// app finishes the sign-in; none where the host takes none back.
    sign_in_redirect: ?[]const u8 = null,
    /// The machine a thread's workspace is on and its commands run on, and whose files clients read, as Beak opened
    /// it; none where there is none.
    machine: ?h.beak_handle = null,
    /// The machine's name as its person knows it; none where the host knows none.
    machine_name: ?[]const u8 = null,
    /// The shell of the person the machine runs for, by its path, which a terminal runs as a login shell; none where
    /// the host names none.
    shell: ?[]const u8 = null,
    /// The person's own ignore file, as git reads it beneath every repository's own — its `core.excludesFile` — by its
    /// absolute path on the machine; none where the host names none.
    excludes: ?[]const u8 = null,
    /// The Chromium the threads' pages are opened in, by its path, none where the host names none; and the folder its
    /// profile is kept in, none for one that lasts as long as it runs.
    browser: ?[]const u8 = null,
    browser_profile: ?[]const u8 = null,
    /// The home folder of the person the machine runs for, which `~` names in a path; none where the host knows none.
    home: ?[]const u8 = null,
    /// The machine's temporary folders, by their absolute paths, which a sandboxed command writes besides its
    /// workspace; none where the host names none.
    temporary: []const []const u8 = &.{},
    /// What the host keeps for itself on the machine, by absolute paths, which nothing reaching the machine through
    /// Siphon reads or writes: its secrets, its volume, its own runtime files.
    hidden: []const []const u8 = &.{},
    /// The folder a thread's calls read the threads in, by its absolute path, as the host lays its own out; none where
    /// the host shows them nowhere.
    threads: ?[]const u8 = null,
    /// Whether the machine confines a command to the system's sandbox, as Beak opened it: on macOS ever, on Linux with
    /// its helper.
    sandboxes: bool = false,
    /// A folder on the machine where a tool keeps what it could not give whole, a file for each call, for the model to
    /// read; none where the host keeps none.
    outputs: ?[]const u8 = null,
    /// The file of the person's own instructions, for every project, by its absolute path on the machine; none where
    /// the host keeps none.
    instructions: ?[]const u8 = null,
    /// The folder of the person's own skills, for every project, by its absolute path on the machine; none where the
    /// host keeps none.
    skills: ?[]const u8 = null,
    /// The file of the person's own MCP servers, for every project, in the common `mcpServers` shape, by its absolute
    /// path on the machine; none where the host keeps none.
    mcp: ?[]const u8 = null,
};

pub const Options = struct {
    /// How many phases a pump runs at most, so the requests they make are acted on between.
    budget: usize = 64,
    /// The providers models are reached through; they live as long as Siphon.
    providers: []const ai.driver.Provider = &.{},
    /// Where a newer catalogue of models is served, and where the host keeps the one fetched last; none, the bundled
    /// catalogue alone.
    catalogue: ?Catalogue = null,
};

/// A catalogue of models served at `url`, the one fetched last kept in `store` across starts.
pub const Catalogue = struct { url: []const u8, store: ai.refresh.Store };

pub fn open(allocator: Allocator, host: Host, options: Options) !*Siphon {
    const siphon = try allocator.create(Siphon);
    errdefer allocator.destroy(siphon);
    const runtime = try Runtime.open(allocator, .{ .io = host.io, .clock = host.clock, .device = host.device }, .{ .budget = options.budget });
    errdefer runtime.close();
    const models = try ai.Models.init(allocator, .{ .providers = options.providers, .catalogue = if (options.catalogue) |given| .{ .url = given.url, .store = given.store } else null, .host = .{
        .io = host.io,
        .http = host.http,
        .credentials = host.credentials orelse agent.models.no_credentials,
        .files = .{ .context = runtime, .vtable = &.{ .read = readStored } },
        .clock = host.clock,
        .mint = .{ .context = runtime, .vtable = &.{ .mint = mintForModels } },
    } });
    errdefer models.deinit();
    const machine: Machine.Host = .{
        .handle = host.machine,
        .name = host.machine_name,
        .home = host.home,
        .shell = host.shell,
        .excludes = host.excludes,
        .temporary = host.temporary,
        .hidden = host.hidden,
        .threads = host.threads,
        .sandboxes = host.sandboxes,
    };
    siphon.* = .{
        .allocator = allocator,
        .runtime = runtime,
        .models = models,
        .tools = .init(runtime, .{ .machine = machine, .outputs = host.outputs, .mcp = host.mcp }),
        .sources = .{ .table = &siphon.tools, .models = models, .instructions = host.instructions, .skills = host.skills },
        .terminals = .{ .allocator = allocator, .runtime = runtime, .machine = machine },
        .browser = .{ .allocator = allocator, .runtime = runtime, .machine = machine, .program = host.browser, .profile = host.browser_profile },
        .turns = .{ .models = models, .table = &siphon.tools },
        .clients = .init(runtime, models, .{ .credentials = host.credentials, .access = host.access, .sign_in_redirect = host.sign_in_redirect, .machine = machine, .terminals = &siphon.terminals, .browser = &siphon.browser, .servers = &siphon.tools.servers }),
    };
    errdefer siphon.tools.deinit();
    siphon.terminals.listener = siphon.clients.terminalsListener();
    siphon.browser.listener = siphon.clients.browserListener();
    runtime.listen(siphon.clients.listener());
    try siphon.tools.register();
    try tools_.calls.register(runtime, &siphon.tools);
    try tools_.trust.register(runtime);
    try tools_.coding.register(&siphon.tools);
    try tools_.scripts.register(runtime, &siphon.tools);
    try tools_.question.register(runtime, &siphon.tools);
    if (host.browser != null) try tools_.browser.register(&siphon.tools, &siphon.browser);
    try agent.system.register(runtime, &siphon.sources);
    try agent.thread.register(runtime);
    try agent.title.register(runtime);
    try agent.delegate.register(runtime, &siphon.tools);
    try agent.turn.register(runtime, &siphon.turns);
    try agent.compacting.register(runtime);
    try agent.models.register(runtime, models);
    try agent.review.register(runtime, models);
    return siphon;
}

/// Lists the providers' models again, and fetches the catalogue where the host gives its address, off the loop, as a job
/// of the runtime's: from any task, as the host asks once Siphon's loop runs. A listing or a fetch that fails keeps
/// what was there.
pub fn refreshModels(siphon: *Siphon) void {
    siphon.runtime.post(.{ .context = siphon, .run = startRefresh, .drop = leftUnrefreshed });
}

fn startRefresh(context: *anyopaque) void {
    const siphon: *Siphon = @ptrCast(@alignCast(context));
    siphon.runtime.spawn(.{ .context = siphon.models, .run = refreshing, .finish = leftUnrefreshed, .drop = leftUnrefreshed }) catch |err| {
        std.log.scoped(.siphon).warn("the models are not listed again: {s}", .{@errorName(err)});
    };
}

fn refreshing(context: *anyopaque, _: *Waits) void {
    const models: *ai.Models = @ptrCast(@alignCast(context));
    models.refresh() catch |err| std.log.scoped(.siphon).warn("the models are not listed again: {s}", .{@errorName(err)});
}

/// What a refresh leaves behind: nothing, its directory changed in place.
fn leftUnrefreshed(_: *anyopaque) void {}

/// The bytes of a file kept for a thread's messages, as `ai` reads it as a message is sent.
fn readStored(context: *anyopaque, arena: Allocator, ref: []const u8) error{ NotFound, Unavailable, OutOfMemory }![]const u8 {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    return threads.stored.read(runtime.volume, arena, ref) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotFound, error.NotAReference => error.NotFound,
        else => error.Unavailable,
    };
}

/// Keeps `bytes` as a file a thread's messages may give their model, from any task — an image as a model is given
/// one: its reference, its size, and what an image became.
pub fn storeFile(siphon: *Siphon, arena: Allocator, bytes: []const u8) !threads.stored.Kept {
    return threads.stored.keep(siphon.runtime, arena, bytes);
}

/// The bytes of the file `ref` names, from any task.
pub fn storedFile(siphon: *Siphon, arena: Allocator, ref: []const u8) ![]const u8 {
    return threads.stored.read(siphon.runtime.volume, arena, ref);
}

/// The image the file `ref` names, fitted to `box`, from any task.
pub fn storedPicture(siphon: *Siphon, arena: Allocator, ref: []const u8, box: threads.stored.Box) !image.Fitted {
    return threads.stored.picture(siphon.runtime.volume, arena, ref, box);
}

/// An id for what `ai` names, minted from the volume, as every id is; it mints till the year 10889.
fn mintForModels(context: *anyopaque) [36]u8 {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    return runtime.volume.mint(runtime.now()) catch |err| std.debug.panic("the volume minted no id: {s}", .{@errorName(err)});
}

/// Stops the loop, lets go of the clients, closes the runtime — its requests cut off, waiting on to be answered as the
/// volume opens again — then ends the servers no task holds now, and the models.
pub fn close(siphon: *Siphon) void {
    siphon.runtime.stop();
    siphon.clients.deinit();
    siphon.terminals.deinit();
    siphon.browser.deinit();
    siphon.runtime.close();
    siphon.tools.deinit();
    siphon.models.deinit();
    siphon.allocator.destroy(siphon);
}
