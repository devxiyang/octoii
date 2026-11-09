//! The clients of Siphon's protocol: each a connection the host opened for a client of its transport, as who its
//! transport authenticated it to be, which the host gives what the client sends and takes what the client is sent from,
//! in tasks of its own. The runtime's loop alone touches the connections, reached by the work posted to it; the clients
//! hear from the loop as its listener — the threads commits changed, what streams of them, and each pump's end, when
//! the clients are fed.
const Clients = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ai = @import("ai");
const Runtime = @import("../runtime.zig").Runtime;
const Waits = @import("../runtime.zig").Waits;
const threads = @import("../threads.zig");
const settings = @import("../settings.zig");
const Machine = @import("../machine.zig");
const Connection = @import("Connection.zig");
const Access = @import("Access.zig");
const Providers = @import("Providers.zig");
const Terminals = @import("../terminals.zig");
const terminals_ = @import("terminals.zig");
const Browser = @import("../browser.zig");
const Servers = @import("../tools.zig").Servers;
const pages = @import("pages.zig");

const log = std.log.scoped(.siphon);

runtime: *Runtime,
/// The models whose providers the credentials' methods tell of, and the credentials the host keeps; none, none kept.
models: *ai.Models,
credentials: ?ai.driver.Credentials,
/// The host's sessions and the links that pair, which the access methods read and change; none, the host keeps none.
access: ?Access,
/// The providers as clients manage them, and the sign-in that waits.
providers: Providers,
/// The machine whose files clients read and whose terminals they open; none where the host gives none.
machine: Machine.Host,
/// The threads' terminals on the machine.
terminals: *Terminals,
/// The browser the threads' pages are open in.
browser: *Browser,
/// The MCP servers the threads use, which clients are shown.
servers: *Servers,
/// The clients connected, each let go of by the loop once its client is gone.
connections: std.ArrayList(*Connection) = .empty,

/// What the host gives its clients: the providers' credentials it keeps, its sessions and the links that pair, the
/// address a provider's sign-in sends the browser back to, and the machine whose files they read — each none where it
/// gives none.
pub const Host = struct {
    credentials: ?ai.driver.Credentials = null,
    access: ?Access = null,
    sign_in_redirect: ?[]const u8 = null,
    machine: Machine.Host = .{},
    terminals: *Terminals,
    browser: *Browser,
    servers: *Servers,
};

/// The clients of `runtime`, telling of `models` and of what `host` gives.
pub fn init(runtime: *Runtime, models: *ai.Models, host: Host) Clients {
    return .{
        .runtime = runtime,
        .models = models,
        .credentials = host.credentials,
        .access = host.access,
        .providers = .{ .redirect = host.sign_in_redirect },
        .machine = host.machine,
        .terminals = host.terminals,
        .browser = host.browser,
        .servers = host.servers,
    };
}

/// The clients, as what hears of the threads' terminals.
pub fn terminalsListener(clients: *Clients) Terminals.Listener {
    return .{ .context = clients, .changed = terminalsChanged, .wrote = terminalWrote };
}

/// The clients, as what hears of the browser's pages.
pub fn browserListener(clients: *Clients) Browser.Listener {
    return .{ .context = clients, .pagesChanged = pagesChanged, .painted = pagePainted };
}

/// Marks the pages of the thread `tid` as having come, changed or gone, for each client that follows the thread.
fn pagesChanged(context: *anyopaque, tid: []const u8) void {
    const clients: *Clients = @ptrCast(@alignCast(context));
    for (clients.connections.items) |connection| connection.following.changedPages(tid);
}

/// Marks the page `id` as painted anew, for each client that follows it.
fn pagePainted(context: *anyopaque, id: []const u8) void {
    const clients: *Clients = @ptrCast(@alignCast(context));
    for (clients.connections.items) |connection| connection.following.changedPage(id);
}

/// Lets go of what the clients kept of the thread `tid`, as it was deleted: its terminals and its pages closed, and no
/// client following it any more.
pub fn forgetThread(clients: *Clients, tid: []const u8) void {
    clients.terminals.closeThread(tid);
    clients.browser.closeThread(tid);
    for (clients.connections.items) |connection| connection.following.unfollow(tid);
}

/// Has the providers let go of what they keep of the conversations of `gone` — threads deleted — off the loop, as
/// nothing waits for it: a provider not reached keeps them till it lets them go itself.
pub fn forgetConversations(clients: *Clients, gone: []const []const u8) void {
    const forgetting = Forgetting.make(clients.runtime.allocator, clients.models, gone) catch |err| {
        return log.warn("the providers keep the conversations of the threads deleted: {s}", .{@errorName(err)});
    };
    clients.runtime.spawn(.{ .context = forgetting, .run = Forgetting.run, .finish = Forgetting.free, .drop = Forgetting.free }) catch |err| {
        log.warn("the providers keep the conversations of the threads deleted: {s}", .{@errorName(err)});
    };
}

/// The providers' letting go of conversations that ended, as a job of the runtime's.
const Forgetting = struct {
    arena_allocator: std.heap.ArenaAllocator,
    models: *ai.Models,
    conversations: []const []const u8,

    fn make(gpa: Allocator, models: *ai.Models, gone: []const []const u8) Allocator.Error!*Forgetting {
        var arena_allocator: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena_allocator.deinit();
        const arena = arena_allocator.allocator();
        const conversations = try arena.alloc([]const u8, gone.len);
        for (gone, conversations) |tid, *each| each.* = try arena.dupe(u8, tid);
        const forgetting = try arena.create(Forgetting);
        forgetting.* = .{ .arena_allocator = undefined, .models = models, .conversations = conversations };
        forgetting.arena_allocator = arena_allocator;
        return forgetting;
    }

    fn run(context: *anyopaque, _: *Waits) void {
        const forgetting: *Forgetting = @ptrCast(@alignCast(context));
        const arena = forgetting.arena_allocator.allocator();
        for (forgetting.conversations) |conversation| forgetting.models.forget(arena, conversation) catch |err| {
            return log.warn("the providers keep the conversation {s}: {s}", .{ conversation, @errorName(err) });
        };
    }

    fn free(context: *anyopaque) void {
        const forgetting: *Forgetting = @ptrCast(@alignCast(context));
        var arena_allocator = forgetting.arena_allocator;
        arena_allocator.deinit();
    }
};

/// Closes each connection and lets go of it, the loop stopped.
pub fn deinit(clients: *Clients) void {
    for (clients.connections.items) |connection| {
        connection.close();
        connection.release();
    }
    clients.connections.deinit(clients.runtime.allocator);
    clients.providers.deinit();
}

/// The clients, as the runtime's listener.
pub fn listener(clients: *Clients) Runtime.Listener {
    return .{ .context = clients, .changed = changed, .published = published, .pumped = pumped };
}

/// A connection for a client the host's transport opened, as `principal`, who the transport authenticated it to be —
/// none where it holds no session, which `hello` then refuses — from any task: the loop takes it as it pumps. The host
/// gives it what the client sends, takes what the client is sent from it, hangs it up once the client is gone, and lets
/// go of it once its taker is done.
pub fn open(clients: *Clients, principal: ?Access.Principal) Allocator.Error!*Connection {
    const connection = try Connection.create(clients, principal);
    clients.runtime.post(.{ .context = connection, .run = opened, .drop = neverOpened });
    return connection;
}

/// The loop takes the connection opened.
fn opened(context: *anyopaque) void {
    const connection: *Connection = @ptrCast(@alignCast(context));
    const clients = connection.clients;
    clients.connections.append(clients.runtime.allocator, connection) catch neverOpened(context);
}

/// The loop never takes the connection: it is closed and let go of, as one whose client is gone.
fn neverOpened(context: *anyopaque) void {
    const connection: *Connection = @ptrCast(@alignCast(context));
    connection.close();
    connection.release();
}

/// Marks the terminal `id` as having written, for each client that follows it.
fn terminalWrote(context: *anyopaque, id: []const u8) void {
    const clients: *Clients = @ptrCast(@alignCast(context));
    for (clients.connections.items) |connection| connection.following.changedTerminal(id);
}

/// Marks the terminal `id` to be drawn again whole, for each client that follows it.
pub fn terminalRedrawn(clients: *Clients, id: []const u8) void {
    for (clients.connections.items) |connection| connection.following.redrawTerminal(id);
}

/// Marks the terminals of the thread `tid` as having come, taken titles or gone, for each client that follows the
/// thread.
fn terminalsChanged(context: *anyopaque, tid: []const u8) void {
    const clients: *Clients = @ptrCast(@alignCast(context));
    for (clients.connections.items) |connection| connection.following.changedTerminals(tid);
}

/// The size what the clients follow as `views` — their terminals or their pages — is drawn at for `id`, by the views
/// they show it in: two views' sizes made the size both show whole, by `Size.fitting`, as tmux's `window-size smallest`
/// sizes a window, so each shows it whole; none where no client follows it.
pub fn fitted(clients: *const Clients, comptime Size: type, comptime views: []const u8, id: []const u8) ?Size {
    var size: ?Size = null;
    for (clients.connections.items) |connection| {
        const view = (@field(connection.following, views).get(id) orelse continue).size;
        size = if (size) |so_far| Size.fitting(so_far, view) else view;
    }
    return size;
}

/// Takes `connection`, whose client is gone, out of those the loop feeds: the terminals it followed sized to the views
/// left, its outbox closed, the loop's hold let go.
pub fn leave(clients: *Clients, connection: *Connection) void {
    for (clients.connections.items, 0..) |each, index| if (each == connection) {
        _ = clients.connections.swapRemove(index);
        break;
    };
    // A terminal or a page that cannot be laid out again keeps its size until a view of it changes.
    for (connection.following.terminals.keys()) |id| terminals_.fit(clients, id) catch {};
    for (connection.following.pages.keys()) |id| pages.fit(clients, id) catch {};
    connection.close();
    connection.release();
}

/// Lets go of each client that holds the session `session`, revoked: its outbox closed, so the host ends its transport.
pub fn dropSession(clients: *Clients, session: []const u8) void {
    for (clients.connections.items) |connection| if (connection.holds(session)) connection.close();
}

/// Whether a client connected now holds the session `session`.
pub fn holdsSession(clients: *const Clients, session: []const u8) bool {
    for (clients.connections.items) |connection| if (!connection.closed and connection.holds(session)) return true;
    return false;
}

/// Tells each client of the threads and the settings the commits that changed `paths` touched. A path stands for what is
/// under it too: the root changed, everything may have.
fn changed(context: *anyopaque, paths: []const []const u8) void {
    const clients: *Clients = @ptrCast(@alignCast(context));
    for (paths) |path| {
        if (path.len == 0) {
            for (clients.connections.items) |connection| connection.changedAll();
            return;
        }
        if (isSettings(path)) {
            for (clients.connections.items) |connection| connection.following.changedSettings();
            continue;
        }
        const tid = threads.threadOfChange(path) orelse continue;
        for (clients.connections.items) |connection| connection.changed(tid);
    }
}

/// Whether `path` is the settings' or beneath them.
fn isSettings(path: []const u8) bool {
    return std.mem.startsWith(u8, path, settings.kind) and (path.len == settings.kind.len or path[settings.kind.len] == '/');
}

/// Offers each client what streams of the thread `topic` for its request `key`, by its offset in the stream.
fn published(context: *anyopaque, topic: []const u8, key: []const u8, offset: u64, data: []const u8) void {
    const clients: *Clients = @ptrCast(@alignCast(context));
    for (clients.connections.items) |connection| connection.offer(topic, key, offset, data);
}

/// Feeds each client a page of what it follows that changed; whether a page is left to feed.
fn pumped(context: *anyopaque) bool {
    const clients: *Clients = @ptrCast(@alignCast(context));
    var unfed = false;
    for (clients.connections.items) |connection| unfed = connection.feed() or unfed;
    return unfed;
}
